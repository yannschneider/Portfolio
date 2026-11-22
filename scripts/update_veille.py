#!/usr/bin/env python3
"""Mise à jour automatique de la veille informatique.

Lit des flux RSS/Atom, garde les articles les plus récents et réécrit
les blocs situés entre les marqueurs VEILLE-AUTO de veille.html.
Les articles en anglais sont traduits en français (API publique MyMemory) ;
un article qu'on n'arrive pas à traduire n'est pas publié.
Aucune dépendance : uniquement la bibliothèque standard de Python.

Lancement :  python scripts/update_veille.py
"""
import datetime as dt
import email.utils
import hashlib
import html
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

# --------------------------------------------------------------------------
# SOURCES — modifie librement cette liste.
# "filtre": True  -> on ne garde que les articles contenant un mot-clé du thème
# "langue": "en"  -> articles traduits en français (sinon la langue est détectée)
# --------------------------------------------------------------------------
SOURCES = {
    "reseau": [
        {"nom": "IT-Connect", "url": "https://www.it-connect.fr/feed/", "filtre": True},
        {"nom": "Le Monde Informatique", "url": "https://www.lemondeinformatique.fr/flux-rss/thematique/reseaux/rss.xml", "filtre": False},
        {"nom": "Network World", "url": "https://www.networkworld.com/feed/", "filtre": True, "langue": "en"},
    ],
    "cyber": [
        {"nom": "CERT-FR alertes", "url": "https://www.cert.ssi.gouv.fr/alerte/feed/", "filtre": False},
        {"nom": "CERT-FR actualités", "url": "https://www.cert.ssi.gouv.fr/actualite/feed/", "filtre": False},
        {"nom": "ZATAZ", "url": "https://www.zataz.com/feed/", "filtre": False},
        {"nom": "IT-Connect", "url": "https://www.it-connect.fr/feed/", "filtre": True},
    ],
}

MOTS_CLES = {
    "reseau": ["réseau", "reseau", "network", "wi-fi", "wifi", "routeur", "router", "switch",
               "commutateur", "cisco", "juniper", "aruba", "fortinet", "pfsense", "opnsense",
               "vlan", "sd-wan", "sdwan", "5g", "fibre", "ethernet", "vpn", "firewall",
               "pare-feu", "dns", "dhcp", "ipv6", "bgp", "ubiquiti", "mikrotik"],
    "cyber": ["cyber", "sécurité", "securite", "security", "vulnérabilité", "vulnerabilite",
              "cve", "ransomware", "rançongiciel", "phishing", "hameçonnage", "fuite",
              "piratage", "malware", "faille", "attaque", "anssi", "mfa"],
}

MAX_ARTICLES = 6        # articles affichés par onglet
MAX_PAR_SOURCE = 3      # pour éviter qu'une seule source prenne toute la place
MAX_AGE_JOURS = 45      # on ignore les articles plus anciens
TIMEOUT = 20

RACINE = pathlib.Path(__file__).resolve().parent.parent
PAGE = RACINE / "veille.html"
CACHE = RACINE / "scripts" / "traductions.json"   # évite de retraduire chaque matin

# Traduction : API publique MyMemory, sans clé (environ 5 000 caractères/jour,
# 500 caractères par requête). La veille en consomme moins de 2 000.
API_TRADUCTION = "https://api.mymemory.translated.net/get"

MOIS = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
ATOM = "{http://www.w3.org/2005/Atom}"


def date_fr(d):
    return f"{d.day} {MOIS[d.month - 1]} {d.year}"


def lire_date(texte):
    if not texte:
        return None
    texte = texte.strip()
    try:
        d = email.utils.parsedate_to_datetime(texte)
    except (TypeError, ValueError):
        try:
            d = dt.datetime.fromisoformat(texte.replace("Z", "+00:00"))
        except ValueError:
            return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d


def nettoyer(texte, longueur=220):
    texte = re.sub(r"<[^>]+>", " ", texte or "")
    texte = html.unescape(texte)
    texte = re.sub(r"\s+", " ", texte).strip()
    if len(texte) > longueur:
        texte = texte[:longueur].rsplit(" ", 1)[0] + "…"
    return texte


# Beaucoup de sites (Cloudflare, WordPress) renvoient 403 à un User-Agent
# inconnu : on se présente comme un navigateur classique.
ENTETES = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/130.0 Safari/537.36",
    "Accept": "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5",
    "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.8",
}


def telecharger(url, essais=2):
    for essai in range(essais):
        try:
            req = urllib.request.Request(url, headers=ENTETES)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return r.read().lstrip()  # espaces avant <?xml => XML invalide
        except Exception:
            if essai == essais - 1:
                raise


def analyser(xml_bytes, nom):
    racine = ET.fromstring(xml_bytes)
    articles = []
    # RSS 2.0
    for item in racine.iter("item"):
        articles.append({
            "titre": nettoyer(item.findtext("title"), 160),
            "lien": (item.findtext("link") or "").strip(),
            "resume": nettoyer(item.findtext("description")),
            "date": lire_date(item.findtext("pubDate") or item.findtext("{http://purl.org/dc/elements/1.1/}date")),
            "source": nom,
        })
    # Atom
    for entry in racine.iter(ATOM + "entry"):
        lien = ""
        for l in entry.findall(ATOM + "link"):
            if l.get("rel", "alternate") == "alternate":
                lien = l.get("href", "")
                break
        articles.append({
            "titre": nettoyer(entry.findtext(ATOM + "title"), 160),
            "lien": lien.strip(),
            "resume": nettoyer(entry.findtext(ATOM + "summary") or entry.findtext(ATOM + "content")),
            "date": lire_date(entry.findtext(ATOM + "published") or entry.findtext(ATOM + "updated")),
            "source": nom,
        })
    return [a for a in articles if a["titre"] and a["lien"].startswith("http")]


MOTS_EN = {"the", "and", "of", "to", "in", "for", "with", "is", "on", "are", "how", "what",
           "why", "new", "your", "from", "by", "its", "will", "can", "this", "that", "it", "as"}
MOTS_FR = {"le", "la", "les", "des", "du", "de", "et", "un", "une", "pour", "dans", "est",
           "sur", "avec", "au", "aux", "que", "qui", "en", "par", "ce", "cette", "son", "ses"}


def est_anglais(texte):
    mots = re.findall(r"[a-zà-ÿ']+", texte.lower())
    return sum(m in MOTS_EN for m in mots) > sum(m in MOTS_FR for m in mots)


def traduire(texte, cache, utilises):
    """Traduit un texte anglais en français. Renvoie None en cas d'échec."""
    if not texte:
        return texte
    cle = hashlib.sha1(texte.encode("utf-8")).hexdigest()
    if cle in cache:
        utilises[cle] = cache[cle]
        return cache[cle]
    url = API_TRADUCTION + "?" + urllib.parse.urlencode({"q": texte[:480], "langpair": "en|fr"})
    for essai in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ENTETES["User-Agent"]})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                rep = json.load(r)
            fr = html.unescape((rep.get("responseData") or {}).get("translatedText") or "").strip()
            if rep.get("responseStatus") in (200, "200") and fr and "MYMEMORY WARNING" not in fr.upper():
                utilises[cle] = fr
                return fr
            print(f"  ! traduction refusée : {rep.get('responseDetails') or rep.get('responseStatus')}",
                  file=sys.stderr)
            return None
        except Exception as e:
            if essai == 2:
                print(f"  ! traduction impossible : {e}", file=sys.stderr)
                return None
            time.sleep(2)


def franciser(article, cache, utilises):
    """Met l'article en français. False si c'est impossible (il ne sera pas publié)."""
    anglais = article.get("langue") == "en" or (
        article.get("langue") is None and est_anglais(article["titre"] + " " + article["resume"]))
    if not anglais:
        return True
    titre = traduire(article["titre"], cache, utilises)
    resume = traduire(article["resume"], cache, utilises)
    if not titre or resume is None:
        return False
    article["titre"], article["resume"], article["traduit"] = titre, resume, True
    return True


def correspond(article, theme):
    texte = (article["titre"] + " " + article["resume"]).lower()
    return any(m in texte for m in MOTS_CLES[theme])


def collecter(theme, maintenant):
    limite = maintenant - dt.timedelta(days=MAX_AGE_JOURS)
    tous, vus = [], set()
    for src in SOURCES[theme]:
        try:
            articles = analyser(telecharger(src["url"]), src["nom"])
        except Exception as e:  # une source en panne ne bloque pas les autres
            print(f"  ! {src['nom']} ignorée : {e}", file=sys.stderr)
            continue
        for a in articles:
            a["langue"] = src.get("langue")
        if src.get("filtre"):
            articles = [a for a in articles if correspond(a, theme)]
        articles = [a for a in articles if a["date"] and a["date"] >= limite]
        articles.sort(key=lambda a: a["date"], reverse=True)
        gardes = 0
        for a in articles:
            if a["lien"] in vus or gardes >= MAX_PAR_SOURCE:
                continue
            vus.add(a["lien"])
            tous.append(a)
            gardes += 1
        print(f"  {src['nom']} : {gardes} article(s)")
    tous.sort(key=lambda a: a["date"], reverse=True)
    return tous   # tous les candidats : la sélection finale se fait après traduction


def rendre(articles, maintenant):
    if not articles:
        return '      <p class="veille-feed-empty">Aucun article récent trouvé lors de la dernière mise à jour.</p>'
    lignes = ['      <ul class="veille-feed-list">']
    for a in articles:
        e = html.escape
        resume = f"\n          <p>{e(a['resume'])}</p>" if a["resume"] else ""
        mention = " · traduit de l'anglais" if a.get("traduit") else ""
        lignes.append(f"""        <li class="veille-feed-item">
          <div class="veille-feed-src"><b>{e(a['source'])}</b><span>{date_fr(a['date'])}{mention}</span></div>
          <a href="{e(a['lien'], quote=True)}" target="_blank" rel="noopener">{e(a['titre'])}</a>{resume}
        </li>""")
    lignes.append("      </ul>")
    lignes.append(f'      <p class="veille-feed-stamp">Dernière mise à jour : {date_fr(maintenant)}</p>')
    return "\n".join(lignes)


def main():
    page = PAGE.read_text(encoding="utf-8")
    maintenant = dt.datetime.now(dt.timezone.utc)
    try:
        cache = json.loads(CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    utilises = {}
    total = 0
    for theme in SOURCES:
        print(f"[{theme}]")
        articles = []
        for a in collecter(theme, maintenant):
            if len(articles) >= MAX_ARTICLES:
                break
            if franciser(a, cache, utilises):
                articles.append(a)
            else:
                print(f"  - écarté (traduction indisponible) : {a['titre'][:70]}")
        print(f"  {sum(1 for a in articles if a.get('traduit'))} article(s) traduit(s)")
        total += len(articles)
        if not articles:
            print("  aucun article : bloc laissé tel quel")
            continue
        motif = re.compile(
            rf"(<!-- VEILLE-AUTO:{theme}:START -->\n).*?(\n<!-- VEILLE-AUTO:{theme}:END -->)", re.S)
        if not motif.search(page):
            sys.exit(f"Marqueurs VEILLE-AUTO:{theme} introuvables dans veille.html")
        page = motif.sub(lambda m: m.group(1) + rendre(articles, maintenant) + m.group(2), page)
    PAGE.write_text(page, encoding="utf-8")
    # le cache ne garde que les traductions affichées : il reste petit
    nouveau = json.dumps(dict(sorted(utilises.items())), ensure_ascii=False, indent=1) + "\n"
    if not CACHE.exists() or CACHE.read_text(encoding="utf-8") != nouveau:
        CACHE.write_text(nouveau, encoding="utf-8")
    if total == 0:
        # toutes les sources ont échoué : on fait échouer l'Action pour que ça se voie
        sys.exit("Aucun article récupéré : toutes les sources sont injoignables ou bloquées.")


if __name__ == "__main__":
    main()
