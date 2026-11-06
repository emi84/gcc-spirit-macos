#!/bin/bash
# Enregistre sur ce Mac un travail envoye par le pilote GCC officiel (PC Windows), pour le
# comparer a celui du pilote Mac. Rien ne part au laser pendant la capture.
#
#   1. Lancez ce script sur le Mac : ./capturer-travail-windows.sh
#   2. Sur le PC Windows : Parametres > Imprimantes > Spirit > Proprietes de l'imprimante >
#      onglet Ports > « Configurer le port » : remplacez l'adresse IP de la Spirit par celle du
#      Mac affichee ci-dessous (port 9100, RAW), puis Appliquer.
#   3. Imprimez depuis CorelDRAW (Windows) un petit dessin : une photo ou un aplat + un trait
#      rouge fin. Le fichier arrive ici.
#   4. Remettez l'adresse IP de la Spirit dans le port du PC.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/captures/windows-$(date +%Y%m%d-%H%M%S).prn"
mkdir -p "$DIR/captures"
IPMAC=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "?")
echo "Adresse IP de ce Mac : $IPMAC   (a mettre dans le port du PC, port 9100)"
echo "En attente d'un travail sur le port 9100... (Ctrl+C pour annuler)"
echo "Si macOS demande d'autoriser les connexions entrantes pour « nc », acceptez."
nc -l 9100 > "$OUT"
SIZE=$(wc -c < "$OUT" | tr -d ' ')
if [ "$SIZE" -gt 0 ]; then
    echo "Recu $SIZE octets : $OUT"
    python3 "$DIR/tools/gccdump.py" "$OUT" | head -40
else
    rm -f "$OUT"
    echo "Rien recu."
fi
