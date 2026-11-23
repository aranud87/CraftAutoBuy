# CraftAutoBuy

**Version 1.3.3 pour WoW Forever.**

Lorsque deux modes d’achat sont possibles, **Acheter** ouvre leur devis :
**Acheter sans utiliser la banque** tient compte des sacs seuls ;
**Acheter le complément** tient aussi compte du stock bancaire connu.
Les quantités réellement achetées, y compris les lots du vendeur, sont indiquées
pour chaque choix. **Annuler** et **Échap** ne déclenchent aucun achat.
Après un complément, les composants bancaires restent à récupérer avant de fabriquer.

Le clic sur **Acheter** conserve les quantités et le montant présentés. Si
le vendeur augmente le prix avant le clic, vérifie le nouveau devis et clique
à nouveau. La garantie porte sur le montant total et sur le nombre d’unités
par article : CAB ne dépense jamais plus que le total affiché, mais ne fixe
pas le prix de chaque unité si une offre du vendeur change pendant la visite.
L’infobulle du prix détaille aussi les fournitures nécessaires aux recettes
intermédiaires. Dans la fenêtre du métier, un changement de recette ou de
quantité entre l’affichage et le clic demande une nouvelle validation.

Pour une transmutation à recharge comme Fer en Or, CAB propose au plus une fabrication quand elle est prête. Sous le nom du métier, sa fiche indique la recharge qui suit une fabrication, avec la durée que donne le jeu. Tant que sa recharge est connue et en cours, elle compte pour zéro, même si tu consultes un autre métier. Cela vaut aussi pour les intermédiaires. Le métier ouvert fournit le nombre de charges des recettes qui en ont. CAB retient ces recharges pour ce personnage, y compris après un `/reload` ou une reconnexion. Une recharge qu’il n’a pas notée (lancée sans lui, partagée avec une autre recette, ou perdue lors d’un arrêt brutal du jeu) n’est connue qu’une fois son métier ouvert : ouvre-le avant de te fier à **Max** ou au devis d’achat.

**[Télécharger et mettre à jour CraftAutoBuy sur CurseForge](https://www.curseforge.com/wow/addons/craftautobuy)**

Le champ de quantité définit l’objectif final du projet. Le bouton
**Créer × N** indique la taille du lot qui partira au prochain clic.
Pour un intermédiaire, l’infobulle indique la recette et le nombre de
fabrications du prochain lot.
Pour une recette avec un emplacement facultatif, la fenêtre native conserve
les commandes du jeu et les composants que tu y as choisis. Depuis l’onglet
CAB, le projet utilise les composants obligatoires du schéma de base.
GitHub héberge le code source, les signalements et les notes de version ; les
téléchargements de l'addon prêt à installer sont proposés sur CurseForge.

CraftAutoBuy initialise automatiquement le catalogue des recettes au premier
lancement. Une fenêtre de progression accompagne la lecture en arrière-plan ;
tu peux la masquer et continuer à jouer pendant le chargement.

CraftAutoBuy ajoute un catalogue de recettes fabricables dans la fenêtre des
métiers de **World of Warcraft: Forever 1.60.1**. Il calcule les possibilités
avec les composants en sacs, la banque personnelle connue, les fournitures PNJ
et les recettes intermédiaires apprises.

L'onglet **CraftAutoBuy**, à droite de la fenêtre, regroupe les recettes des
métiers connus. L'onglet **Stock** affiche les sacs et la banque en parallèle,
avec les composants par défaut et une option pour consulter tous les objets.
Les commandes d'achat et de fabrication sont également disponibles dans la
fenêtre habituelle du métier courant.

## L'onglet CAB v2

La liste CAB regroupe les recettes fabricables de tous les métiers connus,
avec deux filtres toujours visibles :

- **Banque**, activé par défaut : prend en compte le stock personnel mémorisé.
  En le décochant, les recettes devenues non fabricables disparaissent de leur
  métier. Si une fabrication reste possible sans banque, la recette reste
  affichée avec sa nouvelle quantité. Le relevé bancaire continue à être conservé.
- **Progression**, désactivé par défaut : en le cochant, seules les recettes
  à la fois fabricables et capables de faire progresser le métier restent
  affichées dans les sections de métier : difficultés orange, jaune ou verte
  selon le jeu. Les recettes de difficulté grise sont exclues. Une chance de
  progression ne garantit pas un point à chaque fabrication. Cette règle
  native s'applique à tous les métiers, sans exclusion manuelle de recettes.

La section **Favoris** reprend les favoris du jeu parmi les recettes apprises
d'objets simples prises en charge par CAB. Les enchantements, les recettes
avec niveaux de qualité et celles sans objet produit ne sont pas inclus.
Ces favoris restent visibles même sans composants ou sans gain de compétence ; leur quantité et leur couleur
suivent la prise en compte de la banque. Une recette non réalisable apparaît
en gris. Les ajouts et retraits se font depuis les favoris natifs du métier.
La recherche s'applique aussi aux favoris. Elle ignore la casse, les accents,
et les espaces et tabulations ordinaires tapées avant ou après le texte. Elle
traite l'apostrophe droite et l'apostrophe typographique de la même façon, et
rapproche des touches du clavier les caractères des noms du jeu : l'espace
insécable devient une espace, les tirets demi-cadratin et cadratin un trait
d'union, et plusieurs espaces de suite comptent pour une.

La liste utilise un seul niveau de sections : **Favoris**, puis un en-tête
par métier, par exemple **Alchimie** ou **Cuisine**. Les recettes apparaissent
directement sous leur métier, sans catégories ni sous-catégories imbriquées.
Chaque en-tête se réduit ou se développe individuellement ; **Tout réduire**
et **Tout développer** agissent sur ces sections principales. Les métiers
sans recette visible sont masqués.

Les filtres, les sections repliées, la dernière recette sélectionnée et la
position dans la liste sont mémorisés par personnage, puis restaurés à la
réouverture, après `/reload` et à la reconnexion, lorsque les recettes sont
encore disponibles. L'absence de données natives de favoris pendant leur
chargement n'est pas interprétée comme une suppression définitive.
Si ces informations ne sont pas encore disponibles après la mise à jour,
ouvre le métier correspondant une première fois pour les actualiser.

Le filtre Banque ne retire aucun composant et ne permet pas la fabrication
directe depuis la banque. Les fournitures PNJ et les intermédiaires connus
restent pris en compte dans les deux positions de ce filtre. Même avec Banque
décoché, racheter des fournitures déjà connues en banque demande de confirmer
le devis pour le projet en cours.

## Transferts dans la banque personnelle

Le bouton **Déposer les composants**, à gauche de la recherche de la banque
personnelle native, dépose les composants des sacs ordinaires dans l'ordre du
sac à dos puis des sacs équipés, avant les sacs spécialisés.

Le bouton **Récupérer les composants en banque**, en bas de la fiche recette
de l'onglet CAB, retire les composants disponibles en banque qui manquent pour
la recette et la quantité déjà sélectionnées. Son infobulle détaille les
composants à récupérer, avec les intermédiaires connus calculés par CAB.
Banque fermée, il indique **Banque non ouverte** en grisé. Il reste désactivé
si aucun composant correspondant n'est à retirer.

Le dépôt suit uniquement le marqueur natif **Composant d'artisanat**, sans se
limiter aux métiers connus. Un poisson cru marqué par le jeu peut donc être
déposé même s'il est comestible. Un objet non marqué, comme le jus de melon,
reste dans les sacs même si une recette l'utilise. Si le marqueur ne peut pas
encore être vérifié, l'objet reste également sur place.
La récupération explicite depuis une fiche CAB peut toujours retirer un
ingrédient demandé par cette recette, même sans ce marqueur natif.
Les piles dont la nature reste inconnue sont laissées sur place et signalées.
La récupération reste limitée à la recette apprise affichée dans CAB ; elle
ne nécessite pas de catalogue de recettes non apprises.

Les déplacements se font un par un, avec vérification des quantités avant
le suivant. **Arrêter**, fermer la banque, entrer en combat ou commencer une
incantation interrompt l'opération. Les objets déjà transférés restent à leur
destination. Aucun achat ni aucune fabrication ne démarre après un retrait.
La commande `/cab stop` interrompt également le transfert. Si la banque ne
contient qu’une partie des ingrédients du lot, la fiche permet de retirer la
partie disponible. Si, après ce retrait, il manque encore des composants
qu’aucun marchand connu ne vend, l’infobulle le signale et le message de fin
le rappelle au lieu d’annoncer un transfert terminé. Le retrait ne dépasse
jamais la liste que le bouton affichait au moment du clic : si elle s’est
allongée entre-temps, le premier clic ne déplace rien, le bouton montre la
nouvelle liste et attend un second clic. À la fin d’un retrait, CAB indique ce
que la fiche demande encore en banque ; rien de plus ne part sans nouveau clic.
Le bouton actif devient **Arrêter** pendant le transfert. Changer la recette
ou la quantité annule la récupération en cours ; un nouveau clic est nécessaire.
Une opération non confirmée demande une vérification de l'inventaire avant
un nouveau clic. Les boutons de fabrication CAB et natifs sont bloqués pendant
le transfert.

Les commandes sont intégrées aux fenêtres existantes. Un addon qui remplace
la banque peut masquer le bouton de dépôt natif. Les banques de compte et de
guilde sont exclues. Les interactions avec les addons qui remplacent la banque
ou les sacs peuvent dépendre de leur propre interface.

## Installation

1. Ferme le jeu, puis extrais le dossier **CraftAutoBuy** du ZIP dans
   `World of Warcraft/_forever_/Interface/AddOns/`.
2. Le fichier doit se trouver à cet emplacement :
   `Interface/AddOns/CraftAutoBuy/CraftAutoBuy.toc`.
3. Relance le jeu et active CraftAutoBuy dans la liste des addons.
4. À la connexion, CAB tente de lire les recettes des métiers connus en
   arrière-plan. À la première initialisation, une petite fenêtre de progression
   s'affiche. Elle laisse le jeu utilisable et se ferme automatiquement à la fin.
   Si les données du jeu ne sont pas encore disponibles, CAB indique les métiers
   en attente. Tu peux toujours ouvrir un métier pour actualiser ses recettes.

Aucune dépendance n'est nécessaire. Le dossier de l'addon doit conserver son
nom **CraftAutoBuy**, notamment pour charger son icône.

Le bouton **Masquer**, la croix et **Échap** masquent cette fenêtre pour la
session en cours ; la lecture continue en arrière-plan et tu peux jouer
normalement. La fenêtre ne se réaffiche pas lorsque l'initialisation du
catalogue est complète. Elle sert à suivre le chargement, sans confirmation
obligatoire ni tutoriel.

Cette initialisation ne déclenche aucun achat ni aucune fabrication. Les
composants de l'onglet **Stock** apparaissent après la première lecture des
recettes. L'affichage **Tous** peut consulter les objets en sacs sans attendre
ce catalogue. La banque est indépendante : l'initialisation ne lit pas une banque
fermée et ne remplace pas la première visite nécessaire pour en mémoriser le
contenu.

La lecture en arrière-plan est prévue pour **Forever 1.60.1, build 70938**.
Sur un autre build, ouvre les métiers normalement pour remplir le catalogue.
L'ouverture normale d'un métier remplace ensuite les données lues en fond par
son catalogue natif complet.

## Acheter puis fabriquer

Dans les composants, la première quantité est le stock réellement présent en
sacs ; le nombre après `/` reste le besoin d'une fabrication. Les sources sont
séparées : **banque en bleu**, **marchand en jaune**, avec le besoin **À acheter**
pour le lot sélectionné. Les recettes de la liste conservent leur compteur de
fabrications possibles. Les quantités ne sont plus mélangées entre parenthèses.

Tu peux acheter les fournitures PNJ manquantes **avant** de récupérer les autres
ingrédients en banque. Le devis tient compte du stock bancaire connu pour éviter
de racheter ce qui s'y trouve déjà. Après cet achat, récupère les composants
nécessaires puis lance la fabrication par un nouveau clic ; l'achat seul ne
fabrique rien.

Si une recette demande des fournitures de plusieurs vendeurs, **Acheter ici**
achète uniquement les composants disponibles chez le marchand ouvert. Le prix
affiché concerne cet achat ; les besoins auprès des autres vendeurs restent
visibles sur la recette. Rends-toi chez le vendeur suivant puis clique à nouveau.
Changer de vendeur ne déclenche aucun achat et un achat partiel ne lance pas
la fabrication.

1. Sélectionne une recette dans le métier habituel ou dans l'onglet CAB.
2. Choisis la **quantité** souhaitée. **Max** remplit seulement cette quantité
   avec le maximum calculé : il n'achète rien et ne fabrique rien. Le calcul
   s’arrête à **1 000 fabrications de la recette choisie**. Dans l’onglet CAB,
   ce plafond vaut aussi pour la quantité saisie à la main.
3. Le clic sur une recette de CAB active son métier avec son sort du grimoire,
   y compris dans les favoris. Passer à une autre recette du même métier ne le
   rouvre pas. Consulter CAB, restaurer une sélection ou changer un filtre
   n'active aucun métier. Si les données restent indisponibles, le bouton
   **Charger le métier** reste proposé ; tu peux aussi ouvrir l'onglet du métier
   à droite, puis revenir dans CAB. Cette activation ne déclenche aucun achat
   ni aucune fabrication et reste bloquée en combat ou pendant une opération.
4. Si des fournitures PNJ manquent, le bouton affiche **Acheter** ou
   **Acheter ici**. Avec l'achat automatique activé, ouvre un marchand qui les
   vend et clique dessus. Le devis porte sur les fournitures de ce vendeur pour
   la quantité choisie.
5. Une fois les ingrédients en sacs, clique sur **Créer × N**. Pour une recette
   limitée à une fabrication par clic, le bouton affiche **Créer × 1** et le
   projet conserve le reste à réaliser. Les charges lisibles du métier actif
   sont prises en compte dans le maximum calculé. Pour des recettes qui se
   convertissent en boucle, comme les transmutations d'essences, ce maximum
   vient d'une recherche bornée : il peut rester sous le maximum réel, jamais
   au-dessus.

**L'achat et la fabrication demandent deux clics distincts.** La réception des
composants ne lance jamais une fabrication. Ouvrir le marchand, consulter une
recette ou activer un réglage n'achète rien.

Si la recette nécessite des intermédiaires connus, ils sont fabriqués avant le
résultat final. **Chaque recette différente demande un nouveau clic.** Par
exemple, un clic peut fabriquer les deux huiles de bouche-noire, puis le clic
suivant le breuvage de respiration aquatique. Les fournitures nécessaires aux
intermédiaires sont incluses dans le calcul et le devis.
Les recettes intermédiaires prises en compte appartiennent au même métier
que la recette choisie.

## Lire les composants

Le détail indique **stock réel en sacs / requis par fabrication**, sans y
ajouter la banque, les achats à venir ou les recettes intermédiaires. Le
compteur des recettes conserve son calcul global, qui réserve les matières
partagées une seule fois.

La liste des composants défile si elle dépasse la place disponible dans CAB.
Dans la fenêtre native, une longue liste passe sur une colonne défilante pour
garder les noms et les sources lisibles, sans recouvrir les coûts ni les boutons.

Sous chaque composant, les indications de source sont séparées :

- **Banque : n**, en bleu : stock personnel connu de ce composant.
- **Marchand : oui**, en jaune : fourniture PNJ reconnue, hors marchand ou pendant le
  chargement de son inventaire.
- **Vendu par ce PNJ / Non vendu par ce PNJ** : disponibilité chez le marchand
  actuellement ouvert, après lecture de ses articles.
- Une quantité marchande indique un stock limité.
- **À acheter : n** : quantité manquante à acheter pour le lot sélectionné,
  intermédiaires compris. Le marchand peut imposer des paquets et donc vendre
  davantage ; le devis détaille alors le surplus.

L'infobulle peut indiquer le dernier vendeur observé. C'est un historique,
pas une garantie de disponibilité actuelle chez ce vendeur ou dans la zone.

Dans les listes, **vert** signifie que les sacs, les achats PNJ et les
intermédiaires connus suffisent ; **bleu** signifie qu'un retrait en banque
est nécessaire. Des fioles en banque ne rendent pas une recette bleue si elles
peuvent être achetées et que les autres matières sont disponibles en sacs.
Les chevrons de progression reprennent les indications de gain de compétence
du jeu ; ils sont distincts de ces couleurs de disponibilité. Le bouton d'action
tient aussi compte du marchand ouvert, du coût et des prérequis de la recette.

## Banque et onglet Stock v2

Ouvre ta banque une première fois pour que CraftAutoBuy enregistre son contenu.
L'onglet **Stock** permet ensuite de consulter les quantités observées, même
loin de la banque. La recherche s'applique aux sacs et à la banque ; elle suit
les mêmes règles que celle de la liste CAB.

- **Composants**, sélectionné par défaut, affiche les ingrédients des recettes
  apprises prises en charge par CAB. Le menu **Métier** peut limiter cette vue
  à Cuisine, Alchimie ou un autre métier connu. Un ingrédient utilisé par
  plusieurs métiers apparaît dans chacun. Ce filtre ne classe pas les ingrédients
  de toutes les recettes non apprises.
- **Tous** montre aussi les autres objets en sacs et dans le relevé bancaire,
  sans dépendre du catalogue des métiers. Le menu Métier est alors désactivé ;
  son choix précédent est conservé pour le retour aux composants.
- L'affichage classique garde deux listes indépendantes. **Inventaire**
  aligne chaque objet sur une ligne commune **Objet / Sacs / Banque / Total**,
  avec un défilement commun. **0** signifie absence connue ; **?** indique une
  quantité inconnue ou à vérifier. Le total n'est affiché que si les deux
  quantités sont connues. Les piles d'un même objet sont additionnées.

Les résumés de capacité indiquent les emplacements totaux, occupés et libres
pour chaque source. Ils comptent tout le contenu, même lorsque les filtres
n'en montrent qu'une partie. Une pile de vingt objets occupe une seule place.
Les places libres des sacs spécialisés sont distinguées des places utilisables
pour n'importe quel objet. La capacité de banque fermée provient du relevé
mémorisé ; une capacité non lue reste inconnue.

Le volet **Capacité et possibilités d'extension** détaille les sacs équipés et
les emplacements bancaires encore déblocables lorsque ces données sont connues.
La taille de sac saisie sert uniquement à comparer un remplacement : le gain
affiché additionne les gains de tous les sacs ordinaires équipés plus petits
que cette taille, hors sac à dos et sacs spécialisés. Deux sacs identiques
sont comptés séparément. Si le type d'un sac plus petit est inconnu, le gain
reste à vérifier. Cette
comparaison ne promet pas qu'un sac de cette taille est possédé ou disponible
chez un marchand. Elle ne remplace, n'achète et ne déplace aucun objet.

Le côté Banque présente aussi le nombre de sacs équipés et leurs tailles.
La même taille saisie calcule leur gain de remplacement, séparément du gain
possible dans les emplacements encore verrouillés (nombre à débloquer x taille).
Le stockage initial de banque n'est pas un sac à remplacer. Les données restent
mémorisées banque fermée ; une lecture inconnue n'est pas affichée comme zéro.

Les filtres, le mode d'affichage et la disposition de Stock sont mémorisés par
personnage. Stock reste une vue de consultation, même pendant une fabrication.

La banque est mémorisée pour ce personnage et conservée après `/reload` ou
reconnexion. Les banques de guilde, de compte et des autres personnages ne sont
pas incluses. Avant toute première lecture, l'addon demande d'ouvrir la banque.
Une lecture incomplète conserve les informations précédentes avec une indication
de vérification nécessaire ; rouvre la banque pour actualiser le relevé.
Si « Lecture de la banque en cours… » revient à chaque visite, regarde si tu
as retiré un sac de banque qui contenait des composants. Si son emplacement
est resté vide et que la quantité d’un de ces composants en banque a baissé,
CAB peut attendre de pouvoir relire cet emplacement avant d’autoriser les
transferts. À la banque, équipe un sac, même vide, dans ce même emplacement.

Avec le filtre **Banque** activé, quand la quantité choisie nécessite des
composants en banque, tu peux aller les récupérer. Si les sacs et les achats
permettent une autre solution, **Acheter** demande de confirmer le nouveau devis,
les lots et le surplus. Quand les deux modes sont possibles, la fenêtre propose
**Acheter sans utiliser la banque** ou **Acheter le complément**, avec les
quantités réellement achetées et leur prix. Ce choix concerne seulement le projet en cours ; il
n'est pas une préférence permanente. Annuler cette confirmation ne dépense rien.
Avec Banque décoché, le calcul reste sans banque, mais cette confirmation est
également demandée avant de racheter des fournitures déjà connues en banque.
L'autorisation porte sur le projet courant et ne s'étend pas aux autres projets.

Ce choix ne remplace pas une matière de base manquante qui ne peut être ni
achetée ni fabriquée avec les composants disponibles. Aucun objet n'est retiré
automatiquement de la banque.

## Coût, lots et marchand

Le coût sous les composants porte sur les **fournitures PNJ manquantes**, y
compris celles des intermédiaires. Les objets déjà possédés ne sont pas valorisés.
Chez le marchand, le devis utilise ses prix et remises actuels. Ailleurs, les
derniers prix observés donnent une estimation ; un prix inconnu reste signalé.

Un clic sur **Acheter** ou **Acheter ici** peut acheter plusieurs composants
différents. Les commandes sont envoyées successivement et leur réception est
vérifiée. Si des fournitures restent à acheter ailleurs, le panier et le devis
sont limités au vendeur ouvert. L'argent doit couvrir ce panier avant le premier
achat ; chaque vendeur supplémentaire demande un nouveau clic.

Chaque article conserve sa propre taille de lot. Deux fioles nécessaires,
vendues par cinq à 20 cuivre, font acheter cinq fioles pour 20 cuivre : les
trois restantes restent en sacs. Il n'existe pas de règle universelle qui
arrondirait tous les composants par cinq.

Le clic fixe les quantités et le montant maximal autorisés pour la phase
d'achat. Les prix, stocks et composants sont revérifiés avant les commandes
suivantes. Un changement peut suspendre le reste du panier ; les achats déjà
effectués sont conservés. La quantité demandée n'est jamais réduite silencieusement.

Si un achat n'est pas confirmé, l'addon évite d'envoyer une commande en double.
Vérifie tes sacs et ton argent. Si la commande reste en attente, utilise
`/cab reconcile` pour identifier l’article, sa quantité et le prix de l’ordre.
Une livraison tardive reste possible. Si les composants sont arrivés
entre-temps, CAB l’indique et demande de rouvrir le marchand avant tout nouvel
achat. Sinon, après vérification, tu peux confirmer la levée du blocage. Un
nouvel achat exige ensuite un nouveau clic.

## Feu, forge et outils

Les prérequis manquants apparaissent en rouge. **Acheter** peut acheter
les fournitures même sans le feu de cuisine, la forge, l'enclume ou l'outil
nécessaire. Rejoins ensuite le lieu adapté ou récupère l'outil, puis clique sur
**Créer × N**. Arriver sur place ne lance aucune fabrication.

## Arrêter ou changer de recette

Pendant un lot, le bouton affiche **Arrêter** et demande son interruption au
jeu. Les objets déjà fabriqués sont conservés. Le message « Demande de
fabrication annulée. » concerne la demande de CAB ; si le sort ne s'arrête
pas, utilise **Échap**.

Pendant un achat ou une confirmation, le bouton affiche **Annuler**. Une commande
déjà envoyée au marchand peut encore arriver. Au repos, sélectionner une autre
recette abandonne le lot en attente sans perdre les objets déjà présents en sacs.

Un combat, une interruption ou la fermeture du métier peut mettre un projet en
pause. Rétablis les conditions nécessaires puis utilise le bouton d'action
pour reprendre ; aucune reprise de fabrication ne se déclenche toute seule.

## Réglages et langues

Saisis **`/cab`** pour ouvrir les réglages :

- **Achat automatique**, activé par défaut : autorise les achats nécessaires
  au clic sur Acheter, avec un marchand adapté ouvert.
- **Ouvrir les métiers chez les vendeurs de fournitures**, désactivé par
  défaut : ouvre CAB à la prochaine visite d'un marchand qui vend des
  fournitures de craft reconnues. Le contenu du marchand est utilisé, pas son
  titre. Activer l'option chez un vendeur déjà ouvert attend la visite suivante.
- **Langue** : suit le client en mode Automatique, ou utilise le paquet choisi.
  La préférence est enregistrée par personnage et s'applique après `/reload`.

Le mode automatique indique la langue reconnue, par exemple **Automatique
(Français détecté)**. L'anglais sert de repli si la langue est indisponible ou
non détectée, ainsi que pour un texte isolé manquant. Un tel texte ne change
pas l'indication de la langue reconnue.

Les douze paquets fournis sont : français, anglais américain et britannique,
allemand, italien, espagnol d'Espagne et d'Amérique latine, portugais brésilien,
russe, coréen, chinois simplifié et traditionnel. Les noms des recettes, objets
et métiers restent ceux du client WoW, indépendamment de la langue de CAB.

L'interface CAB est prévue pour le clavier et la souris. En mode d'interface
manette, les onglets CAB et Stock sont masqués et les commandes natives du jeu
sont restituées.

## Commandes de discussion

| Commande | Effet |
|---|---|
| `/cab config` | Ouvre les réglages, comme `/cab` ou `/cab options`. |
| `/cab scan` | Relit les recettes du métier que tu as ouvert. |
| `/cab debug` | Affiche dans la discussion les versions de l’addon et du jeu, le métier, la recette sélectionnée et les compteurs du catalogue. |
| `/cab vendor <ID>` | Active ou désactive le classement de l’objet comme fourniture de marchand pour ton personnage. Remplace `<ID>` par le numéro entier positif de l’objet. CAB indique le nouveau classement dans la discussion. Un autre nombre (décimal, nul, négatif ou trop grand) ne change rien et n’affiche rien. |

## Licence

Copyright (c) 2026 aranud87. Distribué sous [licence MIT](LICENSE).
