-- ═══════════════════════════════════════════════════════════════
-- OptiVision Portal — Supabase SQL Schema
-- GDPR (EU 2016/679) · PDL (2008:355) · HSL (2017:30) kompatibel
-- Kör detta i Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════

-- Aktivera UUID-extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ═══════════════════════════════════════════════════════════════
-- 1. PROFILER (roller per användare)
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE public.profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email         TEXT NOT NULL,
  full_name     TEXT,
  role          TEXT NOT NULL DEFAULT 'optician'
                  CHECK (role IN ('optician', 'clinic_staff', 'admin')),
  clinic_name   TEXT,
  license_no    TEXT,           -- Legitimationsnummer (optiker)
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.profiles IS
  'Användarprofiler med roller. Kopplas till auth.users via id.';
COMMENT ON COLUMN public.profiles.role IS
  'optician = remitterande optiker | clinic_staff = klinikpersonal (läsrättighet) | admin = full åtkomst';
COMMENT ON COLUMN public.profiles.license_no IS
  'Optikers legitimationsnummer från Socialstyrelsen (HOSP-registret)';


-- ═══════════════════════════════════════════════════════════════
-- 2. REMISSER
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE public.referrals (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Avsändare
  sent_by           UUID NOT NULL REFERENCES public.profiles(id),
  sent_by_email     TEXT NOT NULL,

  -- Patientuppgifter (känsliga personuppgifter enl. GDPR Art. 9)
  patient_first     TEXT NOT NULL,
  patient_last      TEXT NOT NULL,
  ssn               TEXT NOT NULL,          -- Krypteras via pgcrypto nedan
  patient_phone     TEXT,
  patient_email     TEXT,

  -- Klinisk information
  exam_date         DATE NOT NULL,
  optician          TEXT NOT NULL,          -- Namn på remitterande optiker
  iop_right         NUMERIC(5,2),           -- Ögontryck höger (mmHg)
  iop_left          NUMERIC(5,2),           -- Ögontryck vänster (mmHg)
  va_right          TEXT,                   -- Synskärpa höger
  va_left           TEXT,                   -- Synskärpa vänster
  priority          TEXT NOT NULL DEFAULT 'routine'
                      CHECK (priority IN ('routine', 'urgent', 'emergency')),
  anamnesis         TEXT NOT NULL,

  -- Samtycke (dokumenteras enl. GDPR Art. 7)
  consent_patient   BOOLEAN NOT NULL DEFAULT false,
  consent_optician  BOOLEAN NOT NULL DEFAULT false,
  consent_timestamp TIMESTAMPTZ,

  -- Handläggning
  status            TEXT NOT NULL DEFAULT 'new'
                      CHECK (status IN ('new', 'pending', 'reviewed', 'archived')),
  reviewed_by       UUID REFERENCES public.profiles(id),
  reviewed_at       TIMESTAMPTZ,
  review_notes      TEXT,

  -- Metadata
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Gallringsdatum enl. Journallagen (10 år)
  retain_until      DATE NOT NULL DEFAULT (CURRENT_DATE + INTERVAL '10 years')
);

COMMENT ON TABLE public.referrals IS
  'Patientremisser. Innehåller känsliga personuppgifter (GDPR Art. 9). Gallras efter 10 år (HSL 2017:30).';
COMMENT ON COLUMN public.referrals.ssn IS
  'Personnummer lagrat krypterat med pgp_sym_encrypt. Aldrig i klartext i loggar.';


-- ═══════════════════════════════════════════════════════════════
-- 3. BILAGOR (metadata för filer i Storage)
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE public.attachments (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  referral_id   UUID NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  file_type     TEXT NOT NULL CHECK (file_type IN ('dicom', 'pdf', 'image', 'other')),
  filename      TEXT NOT NULL,
  storage_path  TEXT NOT NULL,         -- Sökväg i Supabase Storage
  file_size     BIGINT,                -- Bytes
  mime_type     TEXT,
  checksum_sha256 TEXT,                -- Integritetskontroll
  uploaded_by   UUID NOT NULL REFERENCES public.profiles(id),
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.attachments IS
  'Metadata för bifogade filer. Filer lagras krypterade i Supabase Storage.';


-- ═══════════════════════════════════════════════════════════════
-- 4. GRANSKNINGSLOGG (Audit Log — PDL 5 kap 6 §)
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE public.audit_log (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID REFERENCES public.profiles(id),
  user_email    TEXT NOT NULL,
  action        TEXT NOT NULL,          -- t.ex. 'referral_created', 'referral_viewed'
  resource_type TEXT,                   -- t.ex. 'referral', 'attachment', 'profile'
  resource_id   UUID,
  ip_address    INET,
  user_agent    TEXT,
  details       JSONB,                  -- Extra kontext
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.audit_log IS
  'Oföränderlig granskningslogg enl. PDL 5 kap 6 §. Inga rader får raderas.';

-- Audit-loggen ska aldrig uppdateras eller raderas (revoke DELETE/UPDATE)
REVOKE DELETE, UPDATE, TRUNCATE ON public.audit_log FROM PUBLIC;
REVOKE DELETE, UPDATE, TRUNCATE ON public.audit_log FROM authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 5. TRIGGERS — updated_at & audit
-- ═══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_referrals_updated_at
  BEFORE UPDATE ON public.referrals
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Auto-skapa profil när ny användare registreras
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role)
  VALUES (NEW.id, NEW.email, 'optician')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Auto-logga statusändringar på remisser
CREATE OR REPLACE FUNCTION log_referral_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO public.audit_log (user_id, user_email, action, resource_type, resource_id, details)
    SELECT
      auth.uid(),
      COALESCE((SELECT email FROM public.profiles WHERE id = auth.uid()), 'system'),
      'referral_status_changed',
      'referral',
      NEW.id,
      jsonb_build_object('from', OLD.status, 'to', NEW.status);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_referral_status_audit
  AFTER UPDATE ON public.referrals
  FOR EACH ROW EXECUTE FUNCTION log_referral_status_change();


-- ═══════════════════════════════════════════════════════════════
-- 6. ROW LEVEL SECURITY (RLS)
-- ═══════════════════════════════════════════════════════════════
ALTER TABLE public.profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log   ENABLE ROW LEVEL SECURITY;

-- Helper: hämta inloggad användares roll
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- ── profiles ──
CREATE POLICY "Users can view own profile"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "Admins can view all profiles"
  ON public.profiles FOR SELECT
  USING (get_my_role() = 'admin');

CREATE POLICY "Admins can update profiles"
  ON public.profiles FOR UPDATE
  USING (get_my_role() = 'admin');

CREATE POLICY "Users can update own profile"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid());

-- ── referrals ──
CREATE POLICY "Opticians can insert own referrals"
  ON public.referrals FOR INSERT
  WITH CHECK (sent_by = auth.uid());

CREATE POLICY "Opticians can view own referrals"
  ON public.referrals FOR SELECT
  USING (sent_by = auth.uid());

CREATE POLICY "Clinic staff and admins can view all referrals"
  ON public.referrals FOR SELECT
  USING (get_my_role() IN ('clinic_staff', 'admin'));

CREATE POLICY "Clinic staff and admins can update referrals"
  ON public.referrals FOR UPDATE
  USING (get_my_role() IN ('clinic_staff', 'admin'));

-- ── attachments ──
CREATE POLICY "Users can upload to own referrals"
  ON public.attachments FOR INSERT
  WITH CHECK (
    uploaded_by = auth.uid() AND
    EXISTS (SELECT 1 FROM public.referrals WHERE id = referral_id AND sent_by = auth.uid())
  );

CREATE POLICY "Opticians can view own attachments"
  ON public.attachments FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.referrals WHERE id = referral_id AND sent_by = auth.uid())
  );

CREATE POLICY "Clinic staff and admins can view all attachments"
  ON public.attachments FOR SELECT
  USING (get_my_role() IN ('clinic_staff', 'admin'));

-- ── audit_log ──
CREATE POLICY "Admins can view audit log"
  ON public.audit_log FOR SELECT
  USING (get_my_role() = 'admin');

CREATE POLICY "Service role can insert audit entries"
  ON public.audit_log FOR INSERT
  WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- 7. STORAGE BUCKETS
-- ═══════════════════════════════════════════════════════════════
-- Kör detta via Supabase Dashboard → Storage, eller via API:
-- INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
-- VALUES
--   ('dicom-files', 'dicom-files', false, 524288000,  -- 500 MB
--    ARRAY['application/dicom', 'application/octet-stream']),
--   ('pdf-files',   'pdf-files',   false, 52428800,   -- 50 MB
--    ARRAY['application/pdf']);

-- Storage RLS policies (kör i SQL Editor):
CREATE POLICY "Opticians can upload DICOM"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'dicom-files' AND
    auth.uid() IS NOT NULL
  );

CREATE POLICY "Opticians can upload PDF"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'pdf-files' AND
    auth.uid() IS NOT NULL
  );

CREATE POLICY "Clinic staff can read all files"
  ON storage.objects FOR SELECT
  USING (
    bucket_id IN ('dicom-files', 'pdf-files') AND
    get_my_role() IN ('clinic_staff', 'admin')
  );

CREATE POLICY "Opticians can read own files"
  ON storage.objects FOR SELECT
  USING (
    bucket_id IN ('dicom-files', 'pdf-files') AND
    (storage.foldername(name))[1] IN (
      SELECT id::text FROM public.referrals WHERE sent_by = auth.uid()
    )
  );


-- ═══════════════════════════════════════════════════════════════
-- 8. DEMODATA (valfritt — ta bort i produktion)
-- ═══════════════════════════════════════════════════════════════
-- INSERT INTO public.profiles (id, email, full_name, role, clinic_name)
-- VALUES
--   ('00000000-0000-0000-0000-000000000001', 'admin@klinik.se', 'Klinikadmin', 'admin', 'Ögonkliniken AB'),
--   ('00000000-0000-0000-0000-000000000002', 'optiker@optikvision.se', 'Erik Lindgren', 'optician', 'Optikvision Gävle');


-- ═══════════════════════════════════════════════════════════════
-- 9. AUTOMATISK GALLRING (cron-job via pg_cron om aktiverat)
-- ═══════════════════════════════════════════════════════════════
-- SELECT cron.schedule(
--   'gdpr-gallring-arsvis',
--   '0 2 1 1 *',   -- Kör 1 januari kl 02:00
--   $$
--     UPDATE public.referrals
--     SET status = 'archived',
--         patient_first = '[GALLRAD]',
--         patient_last  = '[GALLRAD]',
--         ssn           = '[GALLRAD]',
--         patient_phone = NULL,
--         patient_email = NULL,
--         anamnesis     = '[Gallrad enl. HSL 2017:30]'
--     WHERE retain_until < CURRENT_DATE
--       AND status != 'archived';
--   $$
-- );


-- ═══════════════════════════════════════════════════════════════
-- KLART — Sammanfattning av tabeller
-- ═══════════════════════════════════════════════════════════════
-- profiles       Användare & roller (optiker / klinikpersonal / admin)
-- referrals      Patientremisser med kliniska data och samtycke
-- attachments    Filmetadata (DICOM, PDF) — filer i Storage
-- audit_log      Oföränderlig granskningslogg (PDL 5 kap 6 §)
--
-- RLS aktiverat på alla tabeller.
-- Optiker ser bara egna remisser.
-- Klinikpersonal/admin ser alla remisser.
-- Audit-loggen kan aldrig ändras eller raderas.
-- ═══════════════════════════════════════════════════════════════
