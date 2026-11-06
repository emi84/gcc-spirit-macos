#!/bin/bash
# Retire l'imprimante, l'application et tous les fichiers du pilote GCC Spirit (préréglages compris).
set -u
sudo lpadmin -x GCC_Spirit 2>/dev/null && echo "Imprimante retirée."
sudo rm -rf "/Applications/GCC Spirit.app" && echo "Application retirée."
sudo rm -rf /Library/Printers/GCC && echo "Fichiers retirés de /Library/Printers/GCC."
