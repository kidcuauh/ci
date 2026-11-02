#!/usr/bin/env python3
"""Guardia de contenido público (sin red, solo stdlib).

Este repo es público: nada que identifique a una empresa, a una persona o a un
sistema interno debe aparecer en archivos, mensajes de commit, título o cuerpo
de un PR. La guardia no lleva nombres propios en claro:

  * reglas genéricas: dominios fuera de una lista de públicos, owners de
    registros (ghcr.io, github.com, docker.io, quay.io...) fuera de otra,
    correos, UUID e IDs hex de 32, IPv4 e IPv6, rutas locales y referencias
    internas;
  * una lista privada de nombres (--names ARCHIVO), que nunca va en el repo: cada
    entrada se compara, sin separadores, con palabras seguidas del texto (en
    minúsculas y sin acentos) unidas sin separador: cubre guiones, puntos, guiones
    bajos, espacios, camelCase, dígitos y un salto de línea entre dos palabras. Una
    variante pegada a otra palabra sin límite (prefijo o sufijo) no se detecta: hay
    que dar de alta cada variante. Sin --names solo corren las reglas genéricas;
    con --names, un archivo ausente o vacío sale con 2.

Uso:
  check-public-content.py [--root DIR] [--names ARCHIVO] [--text-env VAR]...
                          [--commits RANGO] [--show-tokens]

Sale con 0 si todo está limpio, 1 si hay hallazgos y 2 si el uso es inválido
(incluida una lista de nombres ausente o vacía).
Solo se informa archivo:línea y motivo; el texto del hallazgo no se imprime
salvo con --show-tokens.
"""
import argparse
import ipaddress
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
DATA_DIR = os.path.join(HERE, "public-content")


# Dominios públicos permitidos (el dominio exacto o cualquier subdominio). Solo lo
# que el repo referencia de verdad, más los registros de contenedores.
ALLOWED_DOMAINS = {
    "github.com", "githubusercontent.com", "githubapp.com", "ghcr.io", "gcr.io",
    "public.ecr.aws", "quay.io", "docker.io", "fluxcd.io", "kubernetes.io",
    "k8s.io", "sigstore.dev", "helm.sh", "cnpg.io", "percona.com",
    "infisical.com", "traefik.io", "containo.us", "coreos.com",
    "json-schema.org", "example.com", "example.org", "example.net",
    "anthropic.com", "claude.com", "iana.org", "cluster.local",
}

# Dominios de ejemplo: un correo o un host bajo ellos nunca identifica a nadie.
EXAMPLE_DOMAINS = ("example.com", "example.org", "example.net")

# Último rótulo que cuenta como "parece un dominio": la lista pública de TLD de
# IANA (public-content/tlds.txt), menos los que chocan con extensiones de archivo
# o con expresiones de código (.Release.Name, m.group, v.ingress.host...).
EXCLUDED_TLDS = set("""
sh py md rs pl tf zip mov pub
name group search zone read target new actor run web host email author data date
foo bar link
""".split())


TLD_FILE = os.path.join(DATA_DIR, "tlds.txt")
TLD_REL = os.path.join("scripts", "public-content", "tlds.txt")


# Sufijos de redes privadas que no están en la raíz de IANA.
PRIVATE_SUFFIXES = {"internal", "localdomain", "lan", "corp", "intranet"}


def load_tlds():
    try:
        with open(TLD_FILE, encoding="utf-8") as f:
            tlds = {ln.strip().lower() for ln in f if ln.strip() and not ln.startswith("#")}
    except (OSError, UnicodeDecodeError) as e:
        print(f"ERROR {TLD_FILE}: no se pudo leer la lista de TLD ({e})", file=sys.stderr)
        sys.exit(2)
    tlds = {t for t in tlds if t.isalpha()}
    if "com" not in tlds or len(tlds) < 1000:
        print(f"ERROR {TLD_FILE}: la lista de TLD está incompleta; la regla de dominios no serviría", file=sys.stderr)
        sys.exit(2)
    return (tlds - EXCLUDED_TLDS) | PRIVATE_SUFFIXES


TLDS = load_tlds()

# Owners permitidos en ghcr.io/<x>, github.com/<x>, docker.io/<x>, etc.
ALLOWED_OWNERS = {
    "kidcuauh", "actions", "fluxcd", "sigstore", "helm", "kubernetes",
    "kubernetes-sigs", "yannh", "gitleaks", "mikefarah", "rhysd", "zizmorcore",
    "aquasecurity", "aquasec", "infisical", "cloudnative-pg", "percona", "mi-org",
    "otra-org", "github", "dependabot", "settings", "marketplace", "features",
    "topics", "search",
}

ALLOWED_IPV4_NETS = [ipaddress.ip_network(n) for n in (
    "127.0.0.1/32", "0.0.0.0/32", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
)]
ALLOWED_IPV6_NETS = [ipaddress.ip_network(n) for n in ("2001:db8::/32", "::1/128", "::/128")]
NETMASK_OCTETS = {0, 128, 192, 224, 240, 248, 252, 254, 255}

# Extensiones de archivo binario que se aceptan sin poder leerlas.
BINARY_OK = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp"}

RE_DOMAIN = re.compile(r"(?<![A-Za-z0-9-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,24}))(?![\w-])")
# "<dominio>.com-tls" o "<dominio>.com_respaldo": nombres de certificados o respaldos.
RE_DOMAIN_COM_SUFFIX = re.compile(r"(?<![A-Za-z0-9-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+com)(?=[-_])", re.I)
RE_OWNER = re.compile(
    r"(?<![\w-])((?:[A-Za-z0-9-]+\.)*)"
    r"(registry\.hub\.docker\.com|registry-1\.docker\.io|github\.com|githubusercontent\.com|"
    r"ghcr\.io|docker\.io|quay\.io|gcr\.io|public\.ecr\.aws|pkg\.dev)"
    r"[/:]([^\s\"'<>)\]`,;]+)", re.I)
RE_PLACEHOLDER = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[^A-Za-z0-9]*|\{\{.*")
RE_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
RE_UUID = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f])")
RE_HEX32 = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])")
RE_IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)")
RE_IPV6 = re.compile(r"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:.])")
RE_PATHS = re.compile(
    r"/(?:Us" r"ers|Vol" r"umes)/[^\s/]"
    r"|/ho" r"me/(?!(?:runner|app|node|nonroot)(?:[/\s\"']|$))[^\s/]"
    r"|(?<![\w.])/ro" r"ot/(?!\.)[^\s]"
    r"|~/Doc" r"uments"
    r"|\b[A-Za-z]:\\(?:Users|Documents|Windows|Program)", re.I)
RE_INTERNAL = re.compile(r"\b(?:TASK|TAREA|ADR)[-_ ]?\d|\bdoc-\d", re.I)
RE_WORD = re.compile(r"[a-z0-9]+")


def strip_marks(text):
    """NFKD sin marcas de acento ni caracteres invisibles (ancho cero, etc.)."""
    d = unicodedata.normalize("NFKD", text)
    return "".join(c for c in d if not unicodedata.combining(c) and unicodedata.category(c) != "Cf")


def normalize(text):
    """Minúsculas, sin acentos ni caracteres invisibles; lo no ASCII queda como separador."""
    return strip_marks(text).lower()


def split_boundaries(text):
    """Separa camelCase y letra/dígito: 'ZorbglubInfra' -> 'Zorbglub Infra'."""
    d = strip_marks(text)
    d = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", d)
    return re.sub(r"(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])", " ", d).lower()


def name_hits(text, names):
    """Nombres de la lista privada en el texto. Cada entrada se compara sin separadores
    (mi-org -> miorg) contra ventanas de palabras seguidas, unidas sin separador, hasta
    el largo de la entrada más larga: cubre guiones, puntos, guiones bajos, espacios,
    camelCase y dígitos."""
    text = re.sub(r"[0-9A-Fa-f]{32,}", " ", text)  # digests e IDs hex: sus trozos serían ruido
    hits = set()
    longest = max((len(n) for n in names), default=0)
    for variant in {normalize(text), split_boundaries(text)}:
        words = RE_WORD.findall(variant)
        for i in range(len(words)):
            joined = ""
            for j in range(i, len(words)):
                joined += words[j]
                if len(joined) > longest:
                    break
                if joined in names:
                    hits.add(joined)
    return hits


def load_names(path):
    """Lista privada de nombres: un token por línea; # inicia un comentario. Se guarda
    cada entrada sin separadores, que es como se compara."""
    if not os.path.isfile(path):
        print(f"ERROR {path}: no existe la lista de nombres", file=sys.stderr)
        sys.exit(2)
    names = set()
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except (OSError, UnicodeDecodeError) as e:
        print(f"ERROR {path}: no se pudo leer la lista de nombres ({e})", file=sys.stderr)
        sys.exit(2)
    for n, raw in enumerate(lines, 1):
        entry = normalize(raw.split("#", 1)[0].strip())
        if not entry:
            continue
        key = re.sub(r"[-._ ]+", "", entry)
        if not re.fullmatch(r"[a-z0-9]+(?:[-._ ]+[a-z0-9]+)*", entry) or len(key) < 3:
            print(f"ERROR {path}:{n}: entrada que la guardia nunca encontraría (letras y dígitos, "
                  "separados por - . _ o espacio, y 3 o más caracteres)", file=sys.stderr)
            sys.exit(2)
        names.add(key)
    if not names:
        print(f"ERROR {path}: la lista de nombres está vacía; la guardia no revisaría ningún nombre", file=sys.stderr)
        sys.exit(2)
    return names


def domain_allowed(host):
    host = host.lower()
    return any(host == a or host.endswith("." + a) for a in ALLOWED_DOMAINS)


def email_ok(email):
    local, _, dom = email.lower().rpartition("@")
    if dom == "users.noreply.github.com" or dom.endswith(".users.noreply.github.com") or dom == "noreply.github.com":
        return True
    if (local, dom) in {("noreply", "github.com"), ("noreply", "anthropic.com"),
                        ("git", "github.com"), ("support", "github.com")}:
        return True
    return any(dom == d or dom.endswith("." + d) for d in EXAMPLE_DOMAINS)


def ip_ok(text):
    if not text.isascii():
        return False  # dígitos no ASCII con forma de IP: se informa, no se interpreta
    octets = text.split(".")
    if any(int(o) > 255 for o in octets):
        return True  # no es una IPv4 (p. ej. versión con octetos > 255)
    if any(len(o) > 1 and o.startswith("0") for o in octets):
        return False  # ceros a la izquierda: algunos clientes lo leen como IP
    vals = [int(o) for o in octets]
    if all(v in NETMASK_OCTETS for v in vals) and vals == sorted(vals, reverse=True):
        return True  # máscara de red
    ip = ipaddress.ip_address(text)
    return any(ip in net for net in ALLOWED_IPV4_NETS)


def ipv6_ok(text):
    if "::" not in text and text.count(":") != 7:
        return True  # una hora o un par clave:valor, no una IPv6
    groups = [g for g in text.split(":") if g]
    if len(groups) < 2 or max(len(g) for g in groups) < 3:
        return True  # ::add, 0::2: sintaxis de código, no una dirección
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return True
    return any(ip in net for net in ALLOWED_IPV6_NETS)


def owner_problem(m):
    """Devuelve el owner a informar, o None si está permitido."""
    prefix, host = m.group(1).lower(), m.group(2).lower()
    if host == "github.com" and prefix == "api.":
        return None  # api.github.com/repos/...: la ruta no es un owner
    path = [x for x in m.group(3).split("/") if x != ""]
    if not path:
        return None
    first = path[0].lower()
    if first == "v2" and len(path) > 1:
        first = path[1].lower()
    elif host == "github.com" and first in ("orgs", "apps") and len(path) > 1:
        first = path[1].lower()
    elif first in ("orgs", "apps") and host == "github.com":
        return None
    if RE_PLACEHOLDER.fullmatch(first) or len(first) == 1:
        return None  # variable, glob o una sola letra: no identifica a nadie
    return None if first in ALLOWED_OWNERS else first


def variants_of(text):
    """El texto tal cual y una versión sin ofuscaciones simples: %XX, [.] y anchos."""
    out = [text]
    alt = text.replace("[.]", ".").replace("(.)", ".")
    if "%" in alt:
        alt = urllib.parse.unquote(alt)
    alt = strip_marks(unicodedata.normalize("NFKC", alt))
    if alt != text:
        out.append(alt)
    return out


def scan_line(text, names, show):
    """Devuelve la lista de motivos de una línea."""
    out = []

    def shown(s):
        return f": {s}" if show else ""

    def add(msg):
        if msg not in out:
            out.append(msg)

    for t in variants_of(text):
        for m in RE_DOMAIN.finditer(t):
            host, tld = m.group(1), m.group(2).lower()
            if t[m.end():m.end() + 1] == "(":
                continue  # llamada a método: logger.info(...), self.app(...)
            if m.start() > 0 and t[m.start() - 1] == "." and t[max(0, m.start() - 2):m.start() - 1] != "*":
                continue  # .Values.service.internal, {{ .Chart.Home }}: ruta de código, no un dominio
            in_url = re.search(r"(?:://|@|\bwww\.)$", t[:m.start()]) is not None or host.lower().startswith("www.")
            if (tld in TLDS or (in_url and tld in EXCLUDED_TLDS)) and not domain_allowed(host):
                add(f"dominio fuera de la lista de públicos{shown(host)}")
        for m in RE_DOMAIN_COM_SUFFIX.finditer(t):
            if not domain_allowed(m.group(1)):
                add(f"dominio fuera de la lista de públicos{shown(m.group(1))}")
        for m in RE_OWNER.finditer(t):
            owner = owner_problem(m)
            if owner:
                add(f"owner fuera de la lista de permitidos{shown(owner)}")
        for m in RE_EMAIL.finditer(t):
            if not email_ok(m.group(0)):
                add(f"correo{shown(m.group(0))}")
        if RE_UUID.search(t):
            add("UUID")
        if RE_HEX32.search(t):
            add("ID hex de 32 caracteres")
        for m in RE_IPV4.finditer(t):
            if not ip_ok(m.group(0)):
                add(f"IPv4{shown(m.group(0))}")
        for m in RE_IPV6.finditer(t):
            if not ipv6_ok(m.group(0)):
                add(f"IPv6{shown(m.group(0))}")
        if RE_PATHS.search(t):
            add("ruta local")
        if RE_INTERNAL.search(t):
            add("referencia interna de tarea o decisión")
    seen = set()
    for tok in sorted(name_hits(text, names)) if names else ():
        if tok not in seen:
            seen.add(tok)
            add(f"nombre de la lista privada{shown(tok)}")
    return out


def scan_text(label, text, names, show, findings, first_line=1):
    lines = text.splitlines()
    for n, line in enumerate(lines, first_line):
        for why in scan_line(line, names, show):
            findings.append(f"ERROR {label}:{n}: {why}")
    if not names:
        return
    # Un nombre de varias palabras partido entre dos líneas (mensajes de commit a 72 columnas).
    for n in range(len(lines) - 1):
        pair = name_hits(lines[n] + " " + lines[n + 1], names)
        alone = name_hits(lines[n], names) | name_hits(lines[n + 1], names)
        for tok in sorted(pair - alone):
            findings.append(f"ERROR {label}:{n + first_line}: nombre de la lista privada partido en dos líneas"
                            + (f": {tok}" if show else ""))


def read_text(path):
    """Texto del archivo, o None si es binario (con NUL y sin BOM de UTF-16)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    if b"\0" in data:
        return None
    return data.decode("utf-8", errors="replace")


def scan_tree(root, names, show, findings):
    count = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in (".git", "__pycache__"))
        for name in sorted(filenames):
            if name == ".git":  # en un worktree es un archivo con la ruta del repo
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            # El nombre del archivo también se revisa (línea 0).
            for why in scan_line(rel, names, show):
                findings.append(f"ERROR {rel}:0: en el nombre del archivo: {why}")
            if os.path.islink(path):
                # El destino del enlace también se revisa; el contenido solo si está dentro del repo.
                scan_text(f"{rel} (destino del enlace)", os.readlink(path), names, show, findings)
                continue
            if rel == TLD_REL:
                # Datos públicos de IANA (hay TLD que coinciden con nombres comunes): cada
                # línea de datos debe ser un TLD; los comentarios se revisan como el resto.
                count += 1
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        data_lines = f.readlines()
                except OSError as e:
                    findings.append(f"ERROR {rel}: no se pudo leer ({e.strerror})")
                    continue
                if True:
                    for n, line in enumerate(data_lines, 1):
                        line = line.rstrip("\n")
                        if line.startswith("#"):
                            scan_text(rel, line, names, show, findings, first_line=n)
                        elif not re.fullmatch(r"[A-Za-z0-9-]+", line):
                            findings.append(f"ERROR {rel}:{n}: línea que no es un TLD en la lista de TLD")
                continue
            try:
                text = read_text(path)
            except OSError as e:
                findings.append(f"ERROR {rel}: no se pudo leer ({e.strerror})")
                continue
            if text is None:
                if os.path.splitext(name)[1].lower() not in BINARY_OK:
                    findings.append(f"ERROR {rel}: archivo binario que la guardia no puede revisar (solo se aceptan imágenes)")
                continue
            count += 1
            scan_text(rel, text, names, show, findings)
    return count


def scan_commits(root, rng, names, show, findings):
    fmt = "%H%x1f%ae%x1f%ce%x1f%an%x1f%cn%x1f%B%x1e"
    p = subprocess.run(["git", "-C", root, "log", "--format=" + fmt, rng],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"ERROR no se pudo leer el rango de commits '{rng}'", file=sys.stderr)
        sys.exit(2)
    n = 0
    for rec in p.stdout.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        sha, ae, ce, an, cn, body = rec.split("\x1f", 5)
        n += 1
        for role, mail in (("autor", ae), ("committer", ce)):
            ml = mail.lower()
            if not (ml.endswith("@users.noreply.github.com") or ml == "noreply@github.com"):
                findings.append(f"ERROR commit {sha[:7]}: correo de {role} no es de noreply de GitHub")
        for role, name in (("autor", an), ("committer", cn)):
            for why in scan_line(name, names, show):
                findings.append(f"ERROR commit {sha[:7]}: nombre de {role}: {why}")
        scan_text(f"commit {sha[:7]}", body, names, show, findings)
    return n


def main():
    ap = argparse.ArgumentParser(description="Guardia de contenido público")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--names", metavar="ARCHIVO",
                    help="lista privada de nombres (fuera del repo); sin ella solo corren las reglas genéricas")
    ap.add_argument("--text-env", action="append", default=[], metavar="VAR",
                    help="revisa el texto de esta variable de entorno (título o cuerpo de un PR)")
    ap.add_argument("--commits", metavar="RANGO", help="rango de git log a revisar (p. ej. base..head)")
    ap.add_argument("--show-tokens", action="store_true", help="muestra el texto del hallazgo")
    a = ap.parse_args()

    if not os.path.isdir(a.root):
        print(f"ERROR {a.root} no es un directorio", file=sys.stderr)
        return 2

    names = load_names(a.names) if a.names else set()
    findings = []
    files = scan_tree(os.path.abspath(a.root), names, a.show_tokens, findings)
    for var in a.text_env:
        scan_text(f"${var}", os.environ.get(var, ""), names, a.show_tokens, findings)
    commits = 0
    if a.commits:
        commits = scan_commits(os.path.abspath(a.root), a.commits, names, a.show_tokens, findings)

    for f in findings:
        print(f, file=sys.stderr)
    if findings:
        print(f"{len(findings)} hallazgo(s) de contenido público", file=sys.stderr)
        return 1
    lista = f"{len(names)} nombre(s) de la lista privada" if names else "sin lista privada de nombres: solo reglas genéricas"
    print(f"contenido público ok ({files} archivo(s), {commits} commit(s), {lista})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
