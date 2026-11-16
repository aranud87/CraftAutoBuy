# CraftAutoBuy

**1.1.0 — En développement, pour une pull request en brouillon**

Cette branche prépare **l'onglet CAB v2**. La version stable publiée reste
**1.0.1**. Le comportement et le rendu de la 1.1.0 restent à confirmer dans
WoW Forever avant publication.

La version 1.0.1 initialise automatiquement le catalogue des recettes au premier
lancement. Une fenêtre de progression accompagne la lecture en arrière-plan ;
tu peux la masquer et continuer à jouer pendant le chargement.

CraftAutoBuy ajoute un catalogue de recettes fabricables dans la fenêtre des
métiers de **World of Warcraft: Forever 1.60.1**. Il calcule les possibilités
avec les composants en sacs, la banque personnelle connue, les fournitures PNJ
et les recettes intermédiaires apprises.

L'onglet **CraftAutoBuy**, à droite de la fenêtre, regroupe les recettes des
métiers connus. L'onglet **Stock** sépare les composants en sacs et en banque.
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

La section **Favoris** reprend les favoris du jeu. Ils restent visibles même
sans composants ou sans gain de compétence ; leur quantité et leur couleur
suivent la prise en compte de la banque. Une recette non réalisable apparaît
en gris. Les ajouts et retraits se font depuis les favoris natifs du métier.
La recherche s'applique aussi aux favoris.

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
restent pris en compte dans les deux positions de ce filtre.

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
recettes. La banque est indépendante : l'initialisation ne lit pas une banque
fermée et ne remplace pas la première visite nécessaire pour en mémoriser le
contenu.

La lecture en arrière-plan est prévue pour **Forever 1.60.1, build 70938**.
Sur un autre build, ouvre les métiers normalement pour remplir le catalogue.
L'ouverture normale d'un métier remplace ensuite les données lues en fond par
son catalogue natif complet.

## Acheter puis fabriquer

1. Sélectionne une recette dans le métier habituel ou dans l'onglet CAB.
2. Choisis la **quantité** souhaitée. **Max** remplit seulement cette quantité
   avec le maximum calculé : il n'achète rien et ne fabrique rien.
3. Si CAB doit charger le métier, clique **Charger le métier**. Cela charge ses
   données avec son sort du grimoire, sans achat ni fabrication. Si le chargement
   est indisponible, clique sur l'onglet du métier à droite, puis reviens dans CAB.
   Cette étape est normale après `/reload` ou après avoir ouvert un autre métier,
   même si le catalogue est mémorisé. Le bouton disparaît lorsque le métier de
   la recette est chargé ; aucun sort de métier n'est lancé automatiquement.
4. Si des fournitures PNJ manquent, le bouton affiche **Tout acheter**. Avec
   l'achat automatique activé, ouvre un marchand qui les vend et clique dessus.
   Le devis porte sur l'ensemble des fournitures nécessaires à la quantité choisie.
5. Après leur réception, le bouton affiche **Tout créer**. Clique dessus pour
   fabriquer le lot choisi. Ici « tout » désigne la quantité saisie, pas un
   passage automatique au maximum.

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

Le détail indique **en sacs (potentiel) / requis par fabrication**. Le potentiel
peut inclure la banque connue, les intermédiaires et les achats PNJ. Il peut
dépasser le besoin si le marchand vend des lots. Les matières partagées sont
réservées une seule fois dans le plan complet.

Sous chaque composant, les indications de source sont séparées :

- **Banque : n** : stock personnel connu de ce composant.
- **Marchand : oui** : fourniture PNJ reconnue, hors marchand ou pendant le
  chargement de son inventaire.
- **Vendu par ce PNJ / Non vendu par ce PNJ** : disponibilité chez le marchand
  actuellement ouvert, après lecture de ses articles.
- Une quantité marchande indique un stock limité.

L'infobulle peut indiquer le dernier vendeur observé. C'est un historique,
pas une garantie de disponibilité actuelle chez ce vendeur ou dans la zone.

Dans les listes, **vert** signifie que les sacs, les achats PNJ et les
intermédiaires connus suffisent ; **bleu** signifie qu'un retrait en banque
est nécessaire. Des fioles en banque ne rendent pas une recette bleue si elles
peuvent être achetées et que les autres matières sont disponibles en sacs.
Les chevrons de progression reprennent les indications de gain de compétence
du jeu ; ils sont distincts de ces couleurs de disponibilité. Le bouton d'action
tient aussi compte du marchand ouvert, du coût et des prérequis de la recette.

## Banque et onglet Stock

Ouvre ta banque une première fois pour que CraftAutoBuy enregistre ses composants.
L'onglet **Stock** permet ensuite de consulter les quantités observées, même
loin de la banque, avec une recherche et deux listes indépendantes.

La banque est mémorisée pour ce personnage et conservée après `/reload` ou
reconnexion. Les banques de guilde, de compte et des autres personnages ne sont
pas incluses. Avant toute première lecture, l'addon demande d'ouvrir la banque.
Une lecture incomplète conserve les informations précédentes avec une indication
de vérification nécessaire ; rouvre la banque pour actualiser le relevé.

Avec le filtre **Banque** activé, quand la quantité choisie nécessite des
composants en banque, tu peux aller les récupérer. Si les sacs et les achats
permettent une autre solution, le bouton
d'action propose **Continuer sans banque** avec confirmation du nouveau devis,
des lots et du surplus. Ce choix concerne seulement le projet en cours ; il
n'est pas une préférence permanente. Annuler cette confirmation ne dépense rien.

Ce choix ne remplace pas une matière de base manquante qui ne peut être ni
achetée ni fabriquée avec les composants disponibles. Aucun objet n'est retiré
automatiquement de la banque.

## Coût, lots et marchand

Le coût sous les composants porte sur les **fournitures PNJ manquantes**, y
compris celles des intermédiaires. Les objets déjà possédés ne sont pas valorisés.
Chez le marchand, le devis utilise ses prix et remises actuels. Ailleurs, les
derniers prix observés donnent une estimation ; un prix inconnu reste signalé.

Un clic sur **Tout acheter** peut acheter plusieurs composants différents.
Les commandes sont envoyées successivement et leur réception est vérifiée.
Le marchand ouvert doit vendre tout le panier, et l'argent doit couvrir son
coût total avant le premier achat.

Chaque article conserve sa propre taille de lot. Deux fioles nécessaires,
vendues par cinq à 20 cuivre, font acheter cinq fioles pour 20 cuivre : les
trois restantes restent en sacs. Il n'existe pas de règle universelle qui
arrondirait tous les composants par cinq.

Le clic fixe les quantités et le montant maximal autorisés pour la phase
d'achat. Les prix, stocks et composants sont revérifiés avant les commandes
suivantes. Un changement peut suspendre le reste du panier ; les achats déjà
effectués sont conservés. La quantité demandée n'est jamais réduite silencieusement.

Si un achat n'est pas confirmé, l'addon évite d'envoyer une commande en double.
Vérifie tes sacs et ton argent, puis suis le message affiché avant de reprendre.

## Feu, forge et outils

Les prérequis manquants apparaissent en rouge. **Tout acheter** peut acheter
les fournitures même sans le feu de cuisine, la forge, l'enclume ou l'outil
nécessaire. Rejoins ensuite le lieu adapté ou récupère l'outil, puis clique sur
**Tout créer**. Arriver sur place ne lance aucune fabrication.

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
  au clic sur Tout acheter, avec un marchand adapté ouvert.
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

## Licence

Copyright (c) 2026 aranud87. Distribué sous [licence MIT](LICENSE).
