-- =====================================================================
-- Maw3id by Zellia — Phase 0 : schéma Supabase (PostgreSQL) — v2
-- Back-office cabinet + source unique partagée avec n8n/WhatsApp
-- Hypothèse : Supabase = source de vérité ; Google Calendar = miroir sortant
-- À exécuter dans Supabase > SQL Editor
--
-- v2 (06/10/2026) — ajouts vs v1 :
--   • patients.note            (note liée au patient — ex-"notes_secretaire")
--   • table rdv_historique     (= onglet historique_rdv + colonne "acteur")
--   (consentement : volontairement non inclus — à ajouter plus tard)
-- =====================================================================

-- ---------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto";   -- pour gen_random_uuid()

-- ---------------------------------------------------------------------
-- TYPES ÉNUMÉRÉS (statuts & provenance — évite les fautes de frappe)
-- ---------------------------------------------------------------------
-- Statut d'un RDV : reflète ton cycle de vie WhatsApp existant
create type rdv_statut as enum ('confirme', 'annule', 'reporte', 'no_show', 'termine');
-- Provenance d'un RDV / d'une action : traçabilité web app vs WhatsApp
create type rdv_source as enum ('whatsapp', 'webapp');
-- Rôle utilisateur du back-office
create type user_role as enum ('secretaire', 'medecin');
-- Action journalisée dans l'historique (= valeurs de ton onglet historique_rdv)
create type historique_action as enum ('creation', 'report', 'annulation', 'no_show');
-- Qui a déclenché l'action journalisée
create type acteur_type as enum ('patient_whatsapp', 'secretaire', 'systeme');

-- =====================================================================
-- TABLE : cabinets  (racine du multi-tenant — 1 ligne par cabinet)
-- phone_number_id = ta clé multi-tenant Option B1
-- =====================================================================
create table cabinets (
  id               uuid primary key default gen_random_uuid(),
  nom              text not null,
  phone_number_id  text unique not null,          -- clé d'aiguillage WhatsApp entrant
  calendar_id      text,                           -- agenda Google miroir (nullable)
  sheet_id_legacy  text,                           -- ancien Sheet, pour archive/référence
  langue_defaut    text not null default 'fr',     -- fr | ar | darija
  cree_le          timestamptz not null default now()
);

-- =====================================================================
-- TABLE : app_users  (comptes back-office — liés à l'auth Supabase)
-- id = l'uuid de auth.users (Supabase gère le login/mot de passe)
-- =====================================================================
create table app_users (
  id          uuid primary key references auth.users(id) on delete cascade,
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  nom         text not null,
  role        user_role not null default 'secretaire',
  cree_le     timestamptz not null default now()
);
create index idx_app_users_cabinet on app_users(cabinet_id);

-- =====================================================================
-- TABLE : medecins  (praticiens d'un cabinet)
-- =====================================================================
create table medecins (
  id          uuid primary key default gen_random_uuid(),
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  nom         text not null,
  calendar_id text,                                -- agenda propre au médecin (optionnel)
  actif       boolean not null default true,
  cree_le     timestamptz not null default now()
);
create index idx_medecins_cabinet on medecins(cabinet_id);

-- =====================================================================
-- TABLE : actes  (prestations médicales : libellé, durée, prix)
-- Alimente le menu déroulant "choisir un acte" de la web app
-- =====================================================================
create table actes (
  id          uuid primary key default gen_random_uuid(),
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  libelle     text not null,
  duree_min   integer not null default 30,         -- durée par défaut du créneau
  prix        numeric(10,2),                        -- optionnel (dashboard CA potentiel)
  actif       boolean not null default true
);
create index idx_actes_cabinet on actes(cabinet_id);

-- =====================================================================
-- TABLE : patients  (1 patient = N rdv ; normalisé depuis patients_rdv)
-- =====================================================================
create table patients (
  id          uuid primary key default gen_random_uuid(),
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  nom         text not null,
  telephone   text not null,                       -- format 212XXXXXXXXX
  langue      text,                                 -- fr | ar | darija (hérité session)
  note        text,                                 -- 🆕 v2 note DURABLE sur le patient
                                                    --    (ex : "préfère le matin", "paie en espèces")
                                                    --    ⚠️ usage administratif — PAS de donnée de santé
  cree_le     timestamptz not null default now(),
  -- un même numéro ne doit exister qu'une fois par cabinet
  unique (cabinet_id, telephone)
);
create index idx_patients_cabinet on patients(cabinet_id);
create index idx_patients_tel     on patients(cabinet_id, telephone);

-- =====================================================================
-- TABLE : rdv  (cœur du système — lu/écrit par n8n ET la web app)
-- =====================================================================
create table rdv (
  id               uuid primary key default gen_random_uuid(),
  cabinet_id       uuid not null references cabinets(id) on delete cascade,
  patient_id       uuid not null references patients(id) on delete cascade,
  medecin_id       uuid references medecins(id) on delete set null,
  acte_id          uuid references actes(id) on delete set null,
  date_heure       timestamptz not null,           -- début du RDV (tz Africa/Casablanca côté app)
  duree_min        integer not null default 30,
  statut           rdv_statut not null default 'confirme',
  source           rdv_source not null,            -- whatsapp | webapp (obligatoire = traçabilité)
  google_event_id  text,                            -- id de l'événement miroir dans Calendar
  nb_annulations   integer not null default 0,      -- repris de patients_rdv (ciblage anti-no-show)
  note             text,                            -- note liée À CE RDV (ex : "contrôle post-op")
  cree_le          timestamptz not null default now(),
  maj_le           timestamptz not null default now()
);
create index idx_rdv_cabinet      on rdv(cabinet_id);
create index idx_rdv_date         on rdv(cabinet_id, date_heure);   -- requête agenda = la plus fréquente
create index idx_rdv_patient      on rdv(patient_id);
create index idx_rdv_statut       on rdv(cabinet_id, statut);

-- =====================================================================
-- TABLE : rdv_historique  🆕 v2  (= ton onglet historique_rdv + acteur)
-- Journal d'audit : qui a fait quoi, quand, sur quel RDV.
-- On fige date_rdv/heure_rdv au moment de l'action (comme ton Sheet) :
-- l'historique garde l'état tel qu'il était, même si le RDV change après.
-- =====================================================================
create table rdv_historique (
  id               uuid primary key default gen_random_uuid(),
  cabinet_id       uuid not null references cabinets(id) on delete cascade,
  rdv_id           uuid references rdv(id) on delete set null,   -- nullable : trace conservée même si RDV supprimé
  -- colonnes reprises de l'onglet historique_rdv (figées au moment de l'action) :
  telephone        text,                            -- tel du patient au moment de l'action
  prenom           text,                            -- prénom figé
  medecin          text,                            -- médecin figé (texte, comme le Sheet)
  action           historique_action not null,      -- creation | report | annulation | no_show
  date_rdv         date,                            -- date du RDV concerné (figée)
  heure_rdv        text,                            -- heure du RDV concerné (figée, ex "09:30")
  google_event_id  text,                            -- = event_id du Sheet
  -- 🆕 colonne ajoutée pour la web app :
  acteur           acteur_type not null default 'systeme',  -- qui a déclenché (WhatsApp / secrétaire / système)
  acteur_detail    text,                            -- précision libre (ex : nom de la secrétaire)
  horodatage       timestamptz not null default now()
);
create index idx_hist_cabinet on rdv_historique(cabinet_id, horodatage desc);
create index idx_hist_rdv      on rdv_historique(rdv_id);

-- =====================================================================
-- TABLE : liste_attente  (reprise quasi 1:1 de ton onglet actuel)
-- =====================================================================
create table liste_attente (
  id          uuid primary key default gen_random_uuid(),
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  patient_id  uuid not null references patients(id) on delete cascade,
  acte_id     uuid references actes(id) on delete set null,
  priorite    integer not null default 0,           -- plus haut = traité en premier
  note        text,
  cree_le     timestamptz not null default now()
);
create index idx_attente_cabinet on liste_attente(cabinet_id, priorite desc);

-- =====================================================================
-- TABLE : creneaux_bloques  (congés médecin, pauses — besoin web app)
-- =====================================================================
create table creneaux_bloques (
  id          uuid primary key default gen_random_uuid(),
  cabinet_id  uuid not null references cabinets(id) on delete cascade,
  medecin_id  uuid references medecins(id) on delete cascade,
  debut       timestamptz not null,
  fin         timestamptz not null,
  motif       text,                                 -- congé, formation, pause...
  cree_le     timestamptz not null default now()
);
create index idx_bloques_cabinet on creneaux_bloques(cabinet_id, debut);

-- =====================================================================
-- TABLE : sessions  (état conversationnel WhatsApp — logique INCHANGÉE)
-- On conserve le contexte JSON stringifié tel quel ; n8n continue
-- de faire JSON.parse / try-catch dessus exactement comme avant.
-- =====================================================================
create table sessions (
  id               uuid primary key default gen_random_uuid(),
  cabinet_id       uuid not null references cabinets(id) on delete cascade,
  telephone        text not null,                   -- 212XXXXXXXXX
  etat             text not null default 'libre',   -- libre | attente_prenom | attente_confirmation_annul ...
  contexte_json    text,                             -- contexte JSON stringifié (parse côté n8n)
  maj_le           timestamptz not null default now(),
  unique (cabinet_id, telephone)                    -- 1 session active par patient/cabinet
);
create index idx_sessions_lookup on sessions(cabinet_id, telephone);

-- =====================================================================
-- TRIGGER : maj_le auto sur rdv et sessions (horodatage de modification)
-- =====================================================================
create or replace function touch_maj_le()
returns trigger as $$
begin
  new.maj_le = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_rdv_touch      before update on rdv
  for each row execute function touch_maj_le();
create trigger trg_sessions_touch before update on sessions
  for each row execute function touch_maj_le();

-- =====================================================================
-- RLS — Row Level Security (isolation multi-tenant imposée par la BDD)
-- Chaque utilisateur back-office ne voit QUE les lignes de son cabinet.
-- n8n se connecte via le rôle "service_role" qui BYPASSE le RLS
-- (il gère tous les cabinets via phone_number_id) — c'est voulu.
-- =====================================================================

-- Fonction : cabinet_id de l'utilisateur connecté (lu depuis app_users)
create or replace function mon_cabinet_id()
returns uuid as $$
  select cabinet_id from app_users where id = auth.uid();
$$ language sql stable security definer;

-- Active le RLS sur toutes les tables métier
alter table cabinets         enable row level security;
alter table app_users        enable row level security;
alter table medecins         enable row level security;
alter table actes            enable row level security;
alter table patients         enable row level security;
alter table rdv              enable row level security;
alter table rdv_historique   enable row level security;
alter table liste_attente    enable row level security;
alter table creneaux_bloques enable row level security;
alter table sessions         enable row level security;

-- Politique générique : accès uniquement aux lignes de SON cabinet.
-- (répétée par table car PostgreSQL ne permet pas une policy transverse)
create policy p_cabinets  on cabinets         for all using (id = mon_cabinet_id());
create policy p_users     on app_users        for all using (cabinet_id = mon_cabinet_id());
create policy p_medecins  on medecins         for all using (cabinet_id = mon_cabinet_id());
create policy p_actes     on actes            for all using (cabinet_id = mon_cabinet_id());
create policy p_patients  on patients         for all using (cabinet_id = mon_cabinet_id());
create policy p_rdv       on rdv              for all using (cabinet_id = mon_cabinet_id());
create policy p_hist      on rdv_historique   for all using (cabinet_id = mon_cabinet_id());
create policy p_attente   on liste_attente    for all using (cabinet_id = mon_cabinet_id());
create policy p_bloques   on creneaux_bloques for all using (cabinet_id = mon_cabinet_id());
create policy p_sessions  on sessions         for all using (cabinet_id = mon_cabinet_id());

-- =====================================================================
-- SEED — données de départ (1 cabinet test + médecin + actes dentaires)
-- REMPLACER_PHONE_NUMBER_ID : le phone_number_id WhatsApp du cabinet
--   (ta valeur actuelle = 998215733371244)
-- REMPLACER_CALENDAR_ID     : l'id du Google Calendar miroir
--   (ou remplace 'REMPLACER_CALENDAR_ID' par  null  — SANS guillemets — si pas de Calendar)
-- =====================================================================
insert into cabinets (id, nom, phone_number_id, calendar_id, langue_defaut)
values (
  '00000000-0000-0000-0000-000000000001',
  'Cabinet Test Zellia',
  'REMPLACER_PHONE_NUMBER_ID',
  'REMPLACER_CALENDAR_ID',
  'fr'
);

insert into medecins (cabinet_id, nom)
values ('00000000-0000-0000-0000-000000000001', 'Dr. Test');

-- Actes dentaires courants (durées typiques) — à ajuster au cabinet réel
insert into actes (cabinet_id, libelle, duree_min, prix) values
  ('00000000-0000-0000-0000-000000000001', 'Consultation',          20, null),
  ('00000000-0000-0000-0000-000000000001', 'Détartrage',            30, null),
  ('00000000-0000-0000-0000-000000000001', 'Soin carie',            45, null),
  ('00000000-0000-0000-0000-000000000001', 'Extraction',            30, null),
  ('00000000-0000-0000-0000-000000000001', 'Pose implant',          60, null),
  ('00000000-0000-0000-0000-000000000001', 'Contrôle orthodontie',  20, null);

-- =====================================================================
-- FIN — vérifier : select * from actes;  doit renvoyer 6 lignes
-- =====================================================================
