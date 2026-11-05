#!/usr/bin/env python3
"""Mise à jour automatique de la veille informatique.

Lit des flux RSS/Atom, garde les articles les plus récents et réécrit
les blocs situés entre les marqueurs VEILLE-AUTO de veille.html.
Aucune dépendance : uniquement la bibliothèque standard de Python.

Lancement :  python scripts/update_veille.py
"""
import datetime as dt
import email.utils
import html
import pathlib
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

# --------------------------------------------------------------------------
# SOURCES — modifie librement cette liste.
# "filtre": True  -> on ne garde que les articles contenant un mot-clé du thème
# --------------------------------------------------------------------------
SOURCES = {
    "reseau": [
        {"nom": "IT-Connect", "url": "https://www.it-connect.fr/feed/", "filtre": True},
        {"nom": "Le Monde Informatique", "url": "https://www.lemondeinformatique.fr/flux-rss/thematique/reseaux/rss.xml", "filtre": False},
        {"nom": "Network World", "url": "https://www.networkworld.com/feed/", "filtre": True},
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


def telecharger(url):
    req = urllib.request.Request(url, headers={"User-Agent": "portfolio-veille/1.0 (+GitHub Actions)"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


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
    return tous[:MAX_ARTICLES]


def rendre(articles, maintenant):
    if not articles:
        return '      <p class="veille-feed-empty">Aucun article récent trouvé lors de la dernière mise à jour.</p>'
    lignes = ['      <ul class="veille-feed-list">']
    for a in articles:
        e = html.escape
        resume = f"\n          <p>{e(a['resume'])}</p>" if a["resume"] else ""
        lignes.append(f"""        <li class="veille-feed-item">
          <div class="veille-feed-src"><b>{e(a['source'])}</b><span>{date_fr(a['date'])}</span></div>
          <a href="{e(a['lien'], quote=True)}" target="_blank" rel="noopener">{e(a['titre'])}</a>{resume}
        </li>""")
    lignes.append("      </ul>")
    lignes.append(f'      <p class="veille-feed-stamp">Dernière mise à jour : {date_fr(maintenant)}</p>')
    return "\n".join(lignes)


def main():
    page = PAGE.read_text(encoding="utf-8")
    maintenant = dt.datetime.now(dt.timezone.utc)
    for theme in SOURCES:
        print(f"[{theme}]")
        articles = collecter(theme, maintenant)
        if not articles:
            print("  aucun article : bloc laissé tel quel")
            continue
        motif = re.compile(
            rf"(<!-- VEILLE-AUTO:{theme}:START -->\n).*?(\n<!-- VEILLE-AUTO:{theme}:END -->)", re.S)
        if not motif.search(page):
            sys.exit(f"Marqueurs VEILLE-AUTO:{theme} introuvables dans veille.html")
        page = motif.sub(lambda m: m.group(1) + rendre(articles, maintenant) + m.group(2), page)
    PAGE.write_text(page, encoding="utf-8")


if __name__ == "__main__":
    main()
