#!/bin/bash
# Installe le pilote GCC Spirit sur ce Mac : filtre d'impression, imprimante « GCC Spirit (laser) »,
# application de réglages « GCC Spirit » et préréglages par matière.
#
# Usage : ./installer.sh [adresse IP de la Spirit] [dossier contenant vos fichiers .spi]
#   Les .spi sont les fichiers de paramètres du pilote Windows (30W TESA Rose.spi, 30W Magnum.spi…),
#   copiés du PC sur une clé USB. On peut aussi les importer plus tard depuis l'application.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/Library/Printers/GCC
IP="${1:-}"
SPIS="${2:-}"

if [ -z "$IP" ]; then
    read -r -p "Adresse IP de la Spirit [192.168.100.100] : " IP
    IP="${IP:-192.168.100.100}"
fi

echo "Compilation..."
mkdir -p "$DIR/build"
swiftc -O -swift-version 5 -o "$DIR/build/gccspirit" "$DIR"/src/*.swift
APP="$DIR/build/GCC Spirit.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/GCC Spirit" \
    "$DIR/app/GCCSpiritApp.swift" "$DIR/src/Spi.swift" "$DIR/src/Pens.swift" "$DIR/src/Job.swift"
cp "$DIR/app/Info.plist" "$APP/Contents/Info.plist"
codesign -s - --force --deep "$APP" >/dev/null 2>&1 || true

echo "Vérification de la connexion à $IP:9100..."
if nc -z -G 3 "$IP" 9100 2>/dev/null; then
    echo "  La Spirit répond."
else
    echo "  ATTENTION : pas de réponse sur $IP:9100 (machine éteinte, autre IP ou autre réseau ?)."
    echo "  L'installation continue ; corrigez l'IP plus tard avec : ./installer.sh <IP>"
fi

echo "Installation (mot de passe administrateur)..."
sudo install -d -o root -g wheel -m 755 "$DEST" "$DEST/Filters"
sudo install -d -o root -g admin -m 775 "$DEST/Spirit" "$DEST/Spirit/Presets"
sudo install -o root -g wheel -m 755 "$DIR/build/gccspirit" "$DEST/Filters/gccspirit"
sudo install -o root -g admin -m 664 "$DIR/ppd/GCC_Spirit.ppd" "$DEST/Spirit/GCC_Spirit.ppd"
sudo rm -rf "/Applications/GCC Spirit.app"
sudo cp -R "$APP" "/Applications/GCC Spirit.app"

if [ -n "$SPIS" ] && [ -d "$SPIS" ]; then
    n=0
    for f in "$SPIS"/*.[sS][pP][iI]; do
        [ -e "$f" ] || continue
        cp "$f" "$DEST/Spirit/Presets/" && n=$((n + 1))
    done
    echo "  $n préréglage(s) importé(s) de $SPIS"
fi

# L'imprimante, avec la liste des préréglages dans la fenêtre d'impression.
"$DIR/build/gccspirit" --make-ppd "$DEST/Spirit/GCC_Spirit.ppd" "$DIR/build/GCC_Spirit_installe.ppd"
sudo lpadmin -p GCC_Spirit -E -v "socket://$IP:9100" -P "$DIR/build/GCC_Spirit_installe.ppd" \
    -D "GCC Spirit (laser)" -L "Atelier" -o printer-is-shared=false

# L'icône de la barre des menus (elle s'ouvrira ensuite à chaque démarrage du Mac).
pkill -x "GCC Spirit" 2>/dev/null || true
open "/Applications/GCC Spirit.app"

echo
echo "Installé :"
echo "  - imprimante « GCC Spirit (laser) » (socket://$IP:9100)"
echo "  - icône « flamme » dans la barre des menus : choix du préréglage, Réglages…"
echo "PREMIER ESSAI : un préréglage dont vous avez baissé la puissance (10 %), sur une chute."
