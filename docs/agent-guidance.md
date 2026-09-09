# Exécution déportée (à ajouter au CLAUDE.md/AGENTS.md de ton agent)

Cette instance tourne sur une machine sans toolchain (ou volontairement isolée). Pour tout
**travail lourd**, délègue à un poste client.

## Règle

- **Avant** un travail lourd, appelle `which-host` pour connaître l'hôte actif et les postes joignables (+ leur OS).
- Lance les commandes lourdes via **`run-on auto "<commande>"`** :
  - « lourd » = build, compilation, tests, bundling, lint sur gros repo, `docker build`,
    traitements de données, exécution de modèles (GPU), installations de dépendances volumineuses.
  - Restent **locales** (sans `run-on`) : lecture/édition de fichiers, `git` sans réseau,
    petites commandes, `grep`/recherche, génération de texte.
- `run-on auto` choisit seul : hôte de ta connexion courante → sinon 1ᵉʳ poste joignable
  → sinon repli local (désactivé par défaut, voir `RUNON_FALLBACK_LOCAL`). Tu n'as pas à gérer le fallback.
- **Adapte la commande à l'OS** retourné par `which-host` (ex. `pnpm`/`brew` sur macOS,
  PowerShell/`winget` sur Windows). En cas de doute, demande l'OS via `which-host`.
- Le dossier projet est traduit automatiquement : si tu es dans `/workspaces/projet`,
  `run-on` se place dans le workspace équivalent du poste cible.

## Repos locaux montés (SSHFS)

Certains repos ne sont pas sur la machine-cerveau : ils sont **montés depuis un poste** (ex.
`mount-repo laptop /home/you/github/myproject myproject` → `/workspaces/myproject`).
Tu peux les lire/éditer normalement. Quand tu lances `run-on auto` **depuis un repo monté**,
il s'exécute **automatiquement sur le poste propriétaire, au vrai chemin local** (build natif,
pas via le réseau) — tu n'as rien à préciser. `run-on local` force quand même le local.

## Exemples

```bash
which-host
run-on auto "pnpm install && pnpm build"
run-on auto "pytest -q"
run-on desktop-gpu "python train.py"   # cible explicite si besoin (le poste avec le GPU)
run-on local "ls -la"                  # force la machine-cerveau

# Repo local (reste sur le poste, rien sur la machine-cerveau) :
mount-repo laptop /home/you/github/myproject myproject
cd /workspaces/myproject && run-on auto "pnpm build"   # build natif sur laptop
umount-repo myproject
```
