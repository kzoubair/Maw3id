# Guide Supabase — Maw3id by Zellia

> **Aide-mémoire technique** pour comprendre, maintenir et, si besoin, recréer entièrement la base de données du système de rendez-vous.
>
> | | |
> |---|---|
> | **Projet** | `maw3id-zellia` |
> | **Base** | PostgreSQL managé (Supabase) |
> | **Région** | EU (conformité CNDP) |
> | **Schéma** | `phase0_schema.sql` (dans ce dossier) |
> | **Dernière mise à jour** | 07/10/2026 — Phase 0 exécutée et validée (10 tables, RLS actif, seed chargé) |

**Légende d'état :** ✅ Fait · ⏳ À venir

---

## Sommaire

1. [À quoi sert Supabase ici](#1-à-quoi-sert-supabase-ici)
2. [Créer le projet](#2-créer-le-projet--)
3. [Appliquer le schéma (SQL)](#3-appliquer-le-schéma-sql--)
4. [Vérifier l'installation](#4-vérifier-linstallation--)
5. [Les 10 tables, en clair](#5-les-10-tables-en-clair)
6. [Comprendre le RLS (sécurité)](#6-comprendre-le-rls-sécurité--)
7. [Clés et connexion](#7-clés-et-connexion)
8. [Ce qui reste à configurer](#8-ce-qui-reste-à-configurer)
9. [Maintenance & recréation](#9-maintenance--recréation)

---

## 1. À quoi sert Supabase ici

Supabase est la **source unique de vérité** des données du système : une base PostgreSQL hébergée, partagée entre deux « clients » qui lisent et écrivent les mêmes rendez-vous.

| Qui écrit | Comment il sait de quel cabinet il s'agit | Isolation garantie par |
|---|---|---|
| **n8n** (canal patient WhatsApp) | Déduit du `phone_number_id` du message entrant | Le code n8n (voit tout, trie lui-même — rôle `service_role`) |
| **Web app** (secrétaire / médecin) | Déduit de l'utilisateur connecté (table `app_users`) | Le RLS de Supabase (blocage imposé par la base) |

> **Règle d'or :** Google Calendar reste branché en **miroir sortant uniquement** — n8n y pousse une copie des RDV. On n'écrit **jamais** de Calendar vers Supabase, sinon on recrée le problème des deux écrivains.

---

## 2. Créer le projet ✅

> À refaire uniquement en cas de recréation complète. Sinon, le projet existe déjà.

1. **Ouvrir un compte** — aller sur [supabase.com](https://supabase.com), se connecter (GitHub ou e-mail `kzoubair@gmail.com`).
2. **Nouveau projet** — `New project`. Nom : `maw3id-zellia`.
3. **Mot de passe de la base** — générer un mot de passe fort et **le noter en lieu sûr**. C'est le mot de passe PostgreSQL, indispensable pour brancher n8n plus tard. Impossible à récupérer après coup, seulement à réinitialiser.
4. **Région** — choisir une région **EU** (Frankfurt ou Paris). Important pour la conformité CNDP : les données de santé ne transitent plus par les serveurs US.
5. **Plan** — le plan **Free** suffit pour démarrer et pour tout le pilote. Attendre ~2 min que la base se provisionne.

---

## 3. Appliquer le schéma (SQL) ✅

> Toute la structure (tables, sécurité, données de départ) tient dans un seul fichier : `phase0_schema.sql`. On le colle dans l'éditeur SQL, sans aucune connexion à configurer.

1. **Ouvrir le SQL Editor** — menu de gauche → `SQL Editor` (icône `>_`) → `New query`.
2. **Remplacer les deux placeholders** dans la partie SEED (tout en bas du fichier), avant de coller :

   | Chercher | Remplacer par |
   |---|---|
   | `REMPLACER_PHONE_NUMBER_ID` | `'998215733371244'` (avec guillemets) |
   | `REMPLACER_CALENDAR_ID` | l'ID du calendar avec guillemets, **ou** `null` sans guillemets |

3. **Coller et lancer** — tout sélectionner (Ctrl+A), coller dans l'éditeur, cliquer `Run` (ou Ctrl+Entrée). Les 10 tables, le RLS et le seed se créent d'un coup.

> ⚠️ **Si « already exists »** — une erreur `type … already exists` ou `relation … already exists` signifie que le script a déjà tourné une fois. Soit repartir d'une base vierge, soit utiliser une version du script qui commence par `drop … if exists`. Ne jamais relancer par-dessus une base déjà peuplée.

---

## 4. Vérifier l'installation ✅

**Contrôle par requête** — dans le SQL Editor, lancer :

```sql
select libelle, duree_min from actes;
```

Résultat attendu : **6 lignes** (Consultation, Détartrage, Soin carie, Extraction, Pose implant, Contrôle orthodontie).

**Contrôle visuel** — menu de gauche → `Table Editor` → on doit voir les 10 tables listées à la section suivante.

---

## 5. Les 10 tables, en clair

Ce que contient chaque table et d'où elle vient. Les quatre onglets Google Sheets d'origine sont devenus des tables ; quatre tables sont nouvelles (besoins de la web app et de l'audit).

| Table | Rôle | Origine |
|---|---|---|
| `cabinets` | Racine multi-tenant — 1 ligne par cabinet. Porte le `phone_number_id` (clé d'aiguillage) et le `calendar_id` miroir. | ex-onglet `clients` |
| `app_users` | Comptes du back-office (secrétaire, médecin), liés à l'authentification Supabase. Porte le rôle et le cabinet. | nouveau |
| `medecins` | Praticiens d'un cabinet. | nouveau |
| `actes` | Prestations : libellé, durée, prix. Alimente le menu « choisir un acte » de la web app. | nouveau |
| `patients` | Un patient = N rendez-vous. Porte `note` (durable, sur le patient). | ex-`patients_rdv` (éclaté) |
| `rdv` | Cœur du système. Porte `source` (whatsapp/webapp), `google_event_id`, `note` (sur ce RDV), `nb_annulations`. | ex-`patients_rdv` (éclaté) |
| `rdv_historique` | Journal d'audit : qui a fait quoi, quand. Porte la colonne `acteur` (patient WhatsApp / secrétaire / système). | ex-`historique_rdv` + acteur |
| `liste_attente` | File d'attente quand aucun créneau libre. | ex-`liste_attente` |
| `creneaux_bloques` | Congés médecin, pauses — posés depuis la web app. | nouveau |
| `sessions` | État conversationnel WhatsApp (contexte JSON stringifié). Logique inchangée. | ex-`sessions` |

> **Deux niveaux de note :** `rdv.note` = note sur un rendez-vous précis (« contrôle post-op »). `patients.note` = note durable sur le patient (« préfère le matin »). Les deux sont **administratives** — pas de donnée de santé, pour rester dans un régime CNDP léger.

---

## 6. Comprendre le RLS (sécurité) ✅

Le **Row Level Security** est la barrière qui empêche un cabinet de voir les données d'un autre. Elle est imposée par la base, pas par le code de l'app — donc infranchissable même en cas de bug applicatif.

**Comment ça marche** — une fonction `mon_cabinet_id()` lit, pour l'utilisateur connecté, son `cabinet_id` dans `app_users`. Chaque table a une politique « tu ne vois que les lignes de ton cabinet » :

```sql
create policy p_rdv on rdv
  for all using (cabinet_id = mon_cabinet_id());
```

**L'exception n8n** — n8n se connecte avec le rôle `service_role`, qui **contourne le RLS volontairement** : il gère tous les cabinets et fait lui-même le tri par `phone_number_id`. C'est voulu et sûr tant que la clé `service_role` reste secrète (jamais dans la web app).

> ⚠️ **Décision à ne pas oublier** — l'option Supabase « Enable automatic RLS » est laissée **décochée**. Le RLS est déjà activé table par table dans le script (plus maîtrisé). Cette option ne concerne que l'auto-activation sur de futures tables.

---

## 7. Clés et connexion

Trois informations à récupérer pour brancher les autres briques. **À garder en lieu sûr, jamais dans un dépôt public** (voir `.gitignore`).

| Information | Où la trouver | Pour quoi |
|---|---|---|
| Clé `anon` | Settings → API | La future web app (publique, protégée par le RLS) |
| Clé `service_role` 🔒 **secrète** | Settings → API | n8n uniquement — contourne le RLS |
| Chaîne de connexion | Bouton `Connect` (haut) → `Direct connection string` → onglet **Transaction pooler** | Le nœud Postgres de n8n |

**La chaîne de connexion pour n8n** — prendre le **Transaction pooler** (port 6543), pas la Direct connection (problèmes IPv6 fréquents). Elle ressemble à :

```
postgresql://postgres.xxxx:[MOT_DE_PASSE]@aws-0-eu-...pooler.supabase.com:6543/postgres
```

Remplacer `[MOT_DE_PASSE]` par le mot de passe de la base défini à l'étape 2.

---

## 8. Ce qui reste à configurer

On n'y est pas encore, mais voici la suite côté Supabase, dans l'ordre d'arrivée.

### ⏳ Brancher n8n (Phase 1)
- Créer un credential **Postgres** dans n8n avec la chaîne Transaction pooler + le mot de passe de la base.
- Tester d'abord avec un simple `SELECT` avant de toucher au workflow.
- Remplacer les nœuds Google Sheets du Workflow 1 par des nœuds Postgres (requêtes paramétrées par `cabinet_id`).
- Rejouer les 8 scénarios de non-régression WhatsApp.

### ⏳ Authentification de la web app (Phase 2)
- Activer **Authentication** dans Supabase (e-mail + mot de passe) pour les comptes secrétaire / médecin.
- Pour chaque compte créé, insérer la ligne correspondante dans `app_users` avec son `cabinet_id` et son `role` — c'est ce qui fait fonctionner le RLS.

### ⏳ Onboarding d'un nouveau cabinet
- Ajouter une ligne dans `cabinets` (nom, `phone_number_id`, `calendar_id`).
- Ajouter ses `medecins` et ses `actes`.
- Créer les comptes `app_users` du cabinet.
- Côté Google : partager le Calendar du cabinet avec le Service Account (miroir sortant).

### ⏳ Consentement CNDP
Une table de **registre de consentement** (preuve opposable : qui a consenti, quand, quelle version, par quel canal) a été volontairement différée. À rouvrir quand le besoin sera cadré. Ajout sans impact sur l'existant.

### ⏳ Sauvegardes & sécurité
- Vérifier la politique de **backups** (le plan Free garde une fenêtre courte ; passer au plan payant avant la vraie production, données de santé obligent).
- Activer la **double authentification** sur le compte Supabase.
- Garder `phase0_schema.sql` versionné dans ce repo (déjà fait si tu lis ceci depuis Git).

---

## 9. Maintenance & recréation

### Modifier le schéma plus tard
Ne jamais recréer la base pour un petit changement. Pour ajouter une colonne ou une table, écrire un script `ALTER`/`CREATE` additionnel et le lancer dans le SQL Editor. Garder chaque modification dans un fichier versionné (ex. `phase0b_ajouts.sql`).

### Repeupler les données de test
Le seed (1 cabinet, 1 médecin, 6 actes) est à la fin de `phase0_schema.sql`. On peut le relancer seul si les tables existent déjà et sont vides.

### Recréation complète (dernier recours)
1. **Repartir d'une base vierge** — nouveau projet Supabase (étape 2), ou purger l'existant.
2. **Relancer le schéma** — coller `phase0_schema.sql` à jour dans le SQL Editor (étape 3), placeholders remplacés.
3. **Réappliquer les ajouts** — lancer dans l'ordre les scripts d'ajout versionnés (`phase0b`, etc.).
4. **Reconfigurer les accès** — récupérer les nouvelles clés (étape 7), mettre à jour le credential Postgres de n8n et les variables de la web app.

> **Le fichier qui fait foi :** tant que `phase0_schema.sql` (et ses scripts d'ajout) est à jour et versionné dans le repo Git, la base entière est reproductible en quelques minutes. C'est l'intérêt d'avoir une structure en code plutôt qu'à la main.

---

## Ne jamais committer (rappel sécurité)

Ajouter un `.gitignore` et garder **hors du repo** :

- le **mot de passe** de la base PostgreSQL ;
- les clés **`service_role`** et **`anon`** ;
- la **clé JSON du Service Account** Google ;
- tout fichier `.env` contenant ces valeurs.

Committer plutôt un `.env.example` listant les **noms** des variables, sans les valeurs. Le schéma SQL et ce guide ne contiennent aucun secret (le `phone_number_id` n'en est pas un) → sans risque à committer.

---

*Maw3id by Zellia — Supabase / PostgreSQL. État au 07/10/2026 : schéma Phase 0 exécuté et validé (10 tables, RLS actif, seed chargé). La référence de décision est l'ADR-001 dans les documents du projet.*
