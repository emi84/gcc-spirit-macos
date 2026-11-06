# Pilote macOS pour la GCC LaserPro Spirit

Pilote **non officiel** pour graver et découper avec une GCC LaserPro Spirit depuis un Mac, par le
réseau, depuis CorelDRAW ou toute application qui imprime. GCC ne propose pas de pilote pour macOS :
celui-ci reprend les réglages du pilote Windows Spirit V4.25-01.

- Modes **Noir & Blanc** et **Sélection des couleurs**, avec 16 stylos (vitesse, puissance, PPI, air…)
- **Préréglages par matière** : vos fichiers `.spi` du PC Windows se lisent tels quels
- **Gravure et découpe** dans le même travail : les contours fins sont découpés, sans balayage
- Choix de la matière dans la fenêtre d'impression ou depuis une icône de la barre des menus

*[English summary below.](#english-summary)*

> [!WARNING]
> Un laser peut brûler la matière, la machine ou l'atelier. Ce pilote est fourni sans aucune
> garantie. Faites vos premiers essais **à 10 % de puissance**, sur une chute, devant la machine et
> la main près de l'arrêt d'urgence. Ne laissez jamais la machine sans surveillance.

## État du projet

Essayé sur une seule machine : une Spirit en Ethernet, avec CorelDRAW sur un Mac Apple Silicon
sous macOS 27.

| Fonction | État |
|---|---|
| Gravure en Sélection des couleurs | Vérifiée sur la machine |
| Gravure et découpe dans un même travail | Vérifiée sur la machine |
| Orientation, position Centrer, arrêt de l'air en fin de travail | Vérifiés sur la machine |
| Travail en découpe seule, texte en contour découpé lettre par lettre | Vérifié en simulation seulement |
| Autres modèles GCC, connexion USB, versions plus anciennes de macOS | Non essayés |

## Installation

Il vous faut un Mac sous macOS 13 ou plus récent, et la Spirit allumée sur le même réseau.

1. Installez les outils de compilation d'Apple, si ce n'est pas déjà fait :

   ```
   xcode-select --install
   ```

2. Téléchargez ce dépôt (bouton vert **Code > Download ZIP**) et décompressez-le.
3. Sur le PC Windows, exportez vos préréglages sur une clé USB : propriétés de l'imprimante Spirit,
   onglet Option, sélectionnez un préréglage, **Export**. À refaire pour chaque matière.
4. Dans le Terminal, depuis le dossier décompressé :

   ```
   bash installer.sh 192.168.100.100 /Volumes/CLE_USB
   ```

   Indiquez l'adresse IP de votre Spirit, puis le dossier de vos `.spi` (facultatif, vous pourrez
   les importer plus tard).

Le script installe l'imprimante **« GCC Spirit (laser) »** et l'application **GCC Spirit**. Pour tout
retirer : `bash desinstaller.sh`.

## Choisir la matière et régler

Une **flamme** apparaît dans la barre des menus, et revient à chaque démarrage du Mac. Un clic dessus
donne :

- la **liste de vos préréglages** : cliquez une matière, elle devient le réglage actif (✓) ;
- **Réglages…** : une fenêtre aux mêmes onglets que sur Windows.
  - **Option** : Mode, DPI, Miroir, Inverser, Imprimer immédiatement, Unidirectional Engraving,
    tramage, et les fonctions Enregistrer, Charger, Import, Export, Original, Défaut, Effacer.
  - **Stylo** : les 16 stylos (Vitesse, Puissance, PPI, Trame, Vecteur, Air, appelé « Rampe » sur
    Windows, Auto Focus, Defocus, Repeat).
  - **Avancé** : Mode Position (Home, Sans Home, Relatif, Centrer), Bas vers haut, Drilling, Fonction
    Vecteur, épaisseur maximale d'un trait de découpe (0,1 mm par défaut).
  - **Papier** : dimensions, Etendre, rotation du dessin.

**OK** rend ces réglages actifs. La même fenêtre s'ouvre depuis Réglages Système > Imprimantes et
scanners > GCC Spirit > Options et fournitures > Utilitaire.

## Imprimer

Fichier > Imprimer > **GCC Spirit (laser)**. Dans « Avancés », l'option **Preset (matière)** propose
« Réglage actif » (celui coché dans le menu) ou directement un de vos préréglages.

Comme sur Windows, **la couleur décide** :

- En **Sélection des couleurs**, chaque couleur est gravée avec la vitesse et la puissance de son
  stylo : noir = 1, rouge = 2, vert = 3, jaune = 4, bleu = 5, magenta = 6, cyan = 7… Une couleur
  légèrement différente va au stylo le plus proche.
- En **Noir & Blanc**, tout est gravé en niveaux de gris tramés avec le stylo 1.
- Un **contour fin** (0,1 mm ou moins, réglable), dans la couleur d'un stylo dont « Vecteur » est
  coché, est **découpé**. Un trait d'exactement 1 point (0,353 mm) l'est aussi, car macOS élargit à
  1 point les contours trop fins. Pour graver une ligne de cette épaisseur, donnez-lui 0,4 mm.
- Un **texte en contour seul**, sans remplissage, est découpé lettre par lettre. Les lettres qui se
  touchent gardent chacune leur contour : soudez-les dans CorelDRAW pour l'éviter. Avec une police
  OpenType/CFF, le texte reste gravé : convertissez-le en courbes (Ctrl+Q).
- Un texte ou une forme **remplis** sont toujours gravés.

L'orientation par défaut est **Portrait**. Une page plus haute que la zone de la machine (460 mm) est
tournée d'un quart de tour anti-horaire pour s'allonger sur le plateau. Les autres sont gravées telles
qu'elles apparaissent dans l'aperçu.

## Premier essai

1. Prenez une chute, faites la mise au point et placez la tête au centre de la chute si vous êtes en
   mode Centrer.
2. Créez un préréglage d'essai : Réglages… > Stylo, puissance à 10 % sur les stylos utilisés, puis
   Enregistrer.
3. Choisissez-le dans la fenêtre d'impression et imprimez `essai/mire-80x48mm.pdf`.
4. Vérifiez la position, la gravure, puis la découpe.

## Dépannage

Si un contour est gravé au lieu d'être découpé, enregistrez le dessin depuis la fenêtre d'impression
(menu **PDF > Enregistrer au format PDF**), puis, dans le dossier du pilote :

```
build/gccspirit --pdf dessin.pdf --analyse
```

La commande donne, trait par trait, l'épaisseur, la couleur, le stylo et la raison du choix.

| Outil | Rôle |
|---|---|
| `build/gccspirit --pdf dessin.pdf --out travail.prn --preset Bois.spi [--power-limit 10]` | Convertit sans imprimer |
| `build/gccspirit --pdf dessin.pdf --send <IP>` | Envoie directement à la machine |
| `tools/gccdump.py travail.prn` | Affiche le travail en clair |
| `tools/gccview.py travail.prn image.png` | Montre ce que fera le laser (découpes en rouge) |
| `tools/gccjob.py <dossier> <n° de travail>` | Relit le PDF d'un travail déjà imprimé |
| `capturer-travail-windows.sh` | Enregistre ce qu'envoie le pilote Windows, sans rien graver |

Avant de joindre un fichier à un signalement public, vérifiez qu'il ne contient pas de données de
vos clients : un `.prn` contient le nom du document, et un PDF son contenu.

## Non pris en charge

Modes 3D et tampon (gravés en Noir & Blanc), Smart ACT, Preview, Bordure, Cluster, « Use the start
point » / SmartCenter, Etendre AAS / CCD / rotatif / Roll to Roll, Bridge cutting, True Image.

## Fonctionnement

Le filtre d'impression (`src/`, en Swift) reçoit le PDF de CUPS. Il en extrait les tracés de découpe,
rend le reste en bandes raster, puis envoie le travail sur le port TCP 9100 de la machine.
L'application de la barre des menus se trouve dans `app/`. Le format des travaux est décrit dans
[docs/PROTOCOLE.md](docs/PROTOCOLE.md).

## Mentions légales

Projet indépendant, sans lien avec GCC (GCC LaserPro / Great Computer Corporation), qui ne l'a ni
approuvé ni testé. Les noms de marques appartiennent à leurs propriétaires et servent ici uniquement à
indiquer la compatibilité. Le format a été établi par rétro-ingénierie à des fins d'interopérabilité.
Ce dépôt ne contient ni code ni fichier du pilote officiel. Code sous [licence MIT](LICENSE).

## English summary

Unofficial macOS driver for the GCC LaserPro Spirit laser engraver and cutter, over Ethernet. It adds
a CUPS printer, so CorelDRAW or any other app can print to the laser, and a menu bar app with the
settings of the Windows driver: colour mapping, 16 pens, and `.spi` material presets. Thin outlines
are sent as vector cuts, and everything else is engraved as raster.

To install, run `xcode-select --install`, then `bash installer.sh <laser IP> [folder with .spi files]`.
The interface and documentation are in French. It has only been tried on one machine, and cut-only
jobs have only been simulated so far.

Use it at your own risk and start at 10 % power on scrap material. This project is not affiliated
with GCC.
