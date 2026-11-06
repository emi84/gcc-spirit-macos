# Format des travaux GCC LaserPro Spirit (pilote V4.25-01)

Description du format des travaux envoyés à la machine, établie par rétro-ingénierie du pilote
Windows V4.25-01 à des fins d'interopérabilité. Ce document décrit le format uniquement : il ne
contient aucun code ni fichier du pilote officiel.

## Transport

- Réseau : TCP brut, **port 9100** (`prnport.vbs -o raw -n 9100`), IP par défaut 192.168.100.100.
- USB : classe imprimante (port `USB%03d`), PID 8101.

Un travail = une suite d'octets, sans réponse attendue.

## Unités

- Interne du pilote : 0,001 mm (25 400 par pouce).
- Résolution : la valeur affichée est traduite par la table `[Resolution]` de `Spirit.ini`
  (500 → 508 dpi machine, 1000 → 1016, 1500 → 1524, 600 → 762×609…). Les positions raster
  sont en pixels machine de cette résolution, origine en haut à gauche.
- Vecteurs : 1/1016 pouce (`VECTOR_RES` ; ×3 au-delà de 1000 dpi), origine en bas à gauche
  (`VECTOR_COORD = 1`), conversion entière `v = (1016·1000 / dpi) · px / 1000`.
- Décalage machine : `OFFSET = 50000` (50 mm) ajouté aux X absolus (`*p…E`, `*p…X`).

## Déroulement d'une page

Le pilote a deux sorties : HP-GL/2 simple, et « Exp » (GCC). La Spirit (`MACH_TYPE = 1`) utilise
**Exp**, dans cet ordre : en-tête, bandes raster, fin du raster, vecteurs, fin de travail.

## Réglages (fichiers .spi) et commandes

Les préréglages du pilote (`.spi`) sont des fichiers INI :

| Clé .spi | Commande |
|---|---|
| OPTION/MARK_MODE (1 N&B, 2 couleurs, 3 3D, 4 tampon) | `ESC!r1M` / `ESC!r2M`, bandes par stylo en couleurs |
| OPTION/RESOLUTION | `ESC*t…R`, `ESC&u…D` |
| OPTION/MIRROR, INVERT | (rendu) |
| OPTION/IMMEDIATE (« Imprimer immédiatement ») | `ESC!m1S` |
| OPTION/USE_ACC_AREA | `ESC!r1A` (en-tête) |
| ADVANCE/LOW_SPEED | `ESC!s1S` |
| OPTION/IMAGEONEDIRECTION (« Unidirectional Engraving ») | `ESC!r1V` |
| PEN/… (16 stylos) | tables `ESC!v…` |
| ADVANCE/SCALING_X, _Y (‰) | résolution de rendu |
| ADVANCE/POSITION (0 Home, 1 Sans Home, 2 Relatif, 3 Centrer) | `ESC*v<pos+1>M`, positionnement |
| ADVANCE/VECTOR_FUNCTION | ordre / suppression des vecteurs |
| ADVANCE/BOTTOM_UP (« Bas vers haut ») | `ESC!r1B`, lignes de bas en haut |
| ADVANCE/NO_SKIP_WHITE | bandes pleine largeur |
| ADVANCE/DRILLINGTIME | `ESC!h<ms>T` |
| ADVANCE/DRILLCHECK, CUTTINGFIRST | `PH;`, `SP<n>;PH;` |
| ADVANCE/MODE (vecteur avancé) | `ESC!r<n>E` |
| IMAGE_TUNING/FACTOR | `ESC!r<n>N` |
| PAPER/FIELD_X, FIELD_Y (µm), EXTEND | taille de page, `*v…M` +5 |
| RASTER/CONTRAST, HALFTONE, DITHER_MX, DITHER_PT, ERR_DIFFU_TYPE | tramage N&B |

Colonnes du tableau des stylos : Vitesse = SPEED/10, Puissance = POWER, Trame = RAST,
Vecteur = VECT, « Rampe » (Air en anglais) = BLOWR, AF = AUTOFOCUS.

Positionnement selon `[POSITION]` de Spirit.ini (début / fin) : Home 0 / 3, Sans Home 0 / 0,
Relatif 1 / 5, Centrer 2 / 5. Début 0 : `*p…E/F/X/Y` absolus (+ décalage 50 mm) ; 1 : relatifs à
la tête ; 2 : relatifs au centre de l'étendue du travail. Fin 3 : vers le haut-droite ; 5 : retour
au point de départ (`*p<-x>X *p<-y>Y`) ; 0 : rien.

## 1. En-tête (16 stylos, 4 chiffres par stylo)

```
ESC%-12345X ESC E                 UEL + reset
ESC!r<USE_ACC_AREA>A
ESC!m<n>N<nom>                    nom du document, 20 caractères max
ESC!v16R  <16 × '1'|'0'>          '1' si PPI < 1525
ESC!v64I  <16 × %04d PPI>
ESC!v64V  <16 × %04d vitesse>     0…1000
ESC!v64P  <16 × %04d puissance×10>
ESC!v16D  <16 octets binaires>    3 = air+autofocus, 2 = air, 1 = autofocus, 0 = rien
ESC!v64Z  <16 × %04d>             500 − défocalisation si activée, sinon 500
ESC!v64T  <16 × %d%03d>           (largeur si power tuning, sinon 0) puis puissance de tuning
ESC!h<DRILLINGTIME>T
ESC*t<xdpi>R  ESC&u<ydpi>D
ESC!r<IMAGE_TUNING>N  ESC!r<MODE>E
```

## 2. Bandes raster (1 bit par pixel, bit fort à gauche, 1 = brûler)

Noir & Blanc : la page en gris tramée, avec le stylo 1. Sélection des couleurs : chaque pixel va
au stylo de la couleur la plus proche (blanc : rien) ; les bandes sortent stylo par stylo (1 à 16),
chacune avec la vitesse et la puissance de son stylo (`ESC!r…I/K/P`).
Bas vers haut : bandes du bas vers le haut, lignes de la dernière à la première.

Première sortie du travail (positions absolues) :
```
ESC%1A
ESC*p<largeur>A ESC*p<hauteur>B   étendue de tout le travail (sauf à 250 et 125 dpi)
ESC*p<x0−x>C ESC*p<y0−y>D         écrit « -0 » quand c'est 0
ESC*p<x+offset>E ESC*p<y>F
ESC*v1M
ESC*p<x+offset>X ESC*p<y>Y
[ESC*r1A ESC*rC ESC!m1A]          si le stylo a autofocus ou défocalisation
```
Bandes suivantes : `ESC%1A ESC*p<+dx>X ESC*p<+dy>Y`, relatives à la position de la bande
précédente (x de début, y de sa dernière ligne).

Puis, pour chaque bande :
```
ESC*t1Y ESC!r<BOTTOM_UP>B ESC!r<1 N&B | 2 couleurs>M ESC!r<IMAGEONEDIRECTION>V
ESC!r<vitesse>I ESC!r<vitesse>K ESC!r<puissance×10>P
ESC*t<xdpi>R ESC&u<ydpi>D
[ESC!m<IMMEDIATE>S ESC!s<LOW_SPEED>S]   première bande seulement
[ESC!r<air×2>D]                   quand l'air change
ESC*r<lignes>T ESC*r<pixels>S     pixels = octets × 8, octets arrondis à un multiple de 8
ESC*b1M ESC*r1A
ESC*b<n>W <n octets compressés>   × lignes
ESC*rC
```
Bord gauche d'une bande aligné sur 8 pixels.

### Compression des lignes (`ESC*b1M`)

- un octet suivi du même : répétition de 1 à 128 → `count, octet` ;
- sinon bloc littéral → `00 03 n` + n octets, qui s'arrête dès qu'un octet égale le précédent
  (ce premier octet de la répétition suivante reste dans le bloc) ;
- dernier octet isolé → `01 octet` ; fin de ligne → `00 00`.

Vérifié octet pour octet sur les 550 lignes d'un vrai travail GCC.

## 3–4. Vecteurs (HP-GL/2 relatif)

Après un raster : `ESC!r0D ESC*r1A ESC*rC` si l'air était allumé. Sans raster, le premier
segment est précédé d'un bloc de positionnement (`ESC%1A`, vitesse/puissance du stylo,
`*t R`, `&u D`, `*p A/B/C/D/E/F`, `*v1M`, `*p X/Y`, `ESC!m0S ESC!s0S ESC*r1A ESC*rC`).

```
ESC%1B;PR;                        passage en HP-GL/2, coordonnées relatives
PU<dx>,<dy>;                      déplacement depuis la dernière position, si besoin
SP<n>;                            changement de stylo (réglages pris dans l'en-tête)
PD<dx>,<dy>;                      segment de découpe
PH;                               perçage (segment de longueur nulle)
…
PU;ZS0;RS0;
```
Chaque tracé est répété REPEATCOPY fois.

## 5. Fin de travail (position de fin « haut-droite », réglage par défaut)

```
ESC%1A
ESC*p<+X>X ESC*p<+Y>Y             X = largeur page − 5 mm − ½ pouce − x + offset ; Y = 5 mm − y
ESC*r1A ESC*rC
ESC E ESC%-12345X
```

## Ce que CorelDRAW envoie sur Mac (filtre CUPS)

- Contour plus fin que macOS ne sait tracer : élargi à exactement 1 pt.
- Texte en contour seul : du vrai texte en mode de rendu `1 Tr`, police TrueType sous-ensemble
  (`FontFile2`, table cmap (1,0)), souvent dans un repère étiré (largeur de trait différente sur les
  deux axes). Le filtre relit les glyphes (`src/TrueType.swift`) pour les découper.
- Un travail déjà imprimé se relit avec l'opération IPP CUPS-Get-Document (document intact).

## Paramètres machine de la Spirit (`Spirit.ini`, `[MACHINE]`)

`SPEED_MAX = 1067`, `COMP_BYTE = 8`, `COMPRESS = 1`, `VECTOR_RES_X/Y = 1016`,
`VECTOR_COORD = 1`, `OFFSET = 50000`, `MACH_TYPE = 1`, zone `[FIELD]` 640 × 460 mm
(étendue 740 × 460 mm), `MACHINENAME = 1`.
