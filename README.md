# Portfolio — Yann Schneider (BTS SIO SISR)

Site statique, une page par rubrique, hébergé sur GitHub Pages.

## Veille automatique

Chaque matin, la GitHub Action `.github/workflows/veille.yml` lance
`scripts/update_veille.py`, qui lit des flux RSS et réécrit le bloc
« Actualités récentes » de chaque onglet de `veille.html`
(entre les marqueurs `<!-- VEILLE-AUTO:... -->`). Si la page change, l'Action
fait un commit et GitHub Pages republie le site.

- **Lancer à la main** : onglet *Actions* → *Mise à jour de la veille* → *Run workflow*.
- **Changer les sources ou les mots-clés** : listes `SOURCES` et `MOTS_CLES` en haut du script.
- **Tester en local** : `python scripts/update_veille.py`

Les cartes « Mon analyse » ne sont pas touchées : elles restent à rédiger soi-même.
Ne pas modifier le contenu entre les marqueurs, il est écrasé à chaque passage.
