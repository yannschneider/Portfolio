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

### Traduction en français

Les articles en anglais (sources marquées `"langue": "en"`, ou détectées
automatiquement) sont traduits par l'API publique gratuite MyMemory, sans clé.
Un article qu'on n'arrive pas à traduire n'est pas publié : la page reste
toujours en français, et l'article suivant prend sa place. Les articles
traduits portent la mention « traduit de l'anglais ». En local, les
traductions sont gardées dans `scripts/traductions.json` (fichier ignoré par
Git) ; sur GitHub, l'Action retraduit chaque matin, ce qui reste très en
dessous du quota gratuit (moins de 2 000 caractères sur 5 000 par jour).

Les cartes « Mon analyse » ne sont pas touchées : elles restent à rédiger soi-même.
Ne pas modifier le contenu entre les marqueurs, il est écrasé à chaque passage.
