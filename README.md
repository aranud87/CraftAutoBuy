# CraftAutoBuy

**[Download on CurseForge / Télécharger sur CurseForge](https://www.curseforge.com/wow/addons/craftautobuy)**

Crafting planner and inventory overview for **World of Warcraft: Forever**.
Version **1.4.1**.

Recipe loading runs in the background on verified Forever builds. After a game
update awaiting verification, saved recipes remain available. Open the
professions named by CAB to update their recipes.

Deposit crafting reagents at your personal bank or withdraw the materials for
a selected recipe from its CAB tab. Clicking a recipe can open its profession.
At a vendor, choose whether to use your bank stock and check the quantities and
price before buying.

In the CAB tab, the recipe icon shows how many items one craft produces when it makes more than one. Recipes with a variable yield show a range.
**Craft × N** shows how many executions the next click will request. For
intermediate recipes, the tooltip names the recipe and the number of crafts in the next batch.
In the CAB tab, **Max** fills in the planned quantity, up to **1,000 crafts**
of the selected recipe. The same cap applies when you type the quantity.

For a transmute with a cooldown, such as Iron to Gold, CAB offers at most one craft when it is ready. In the CAB tab, a line under the profession name shows the cooldown that follows a craft, with the duration given by the game. While its known cooldown is running, it counts as zero even when you view another profession. This also applies to intermediate crafts. Recipes with charges use the charge count reported by the open profession. CAB remembers these cooldowns for the character, including after a `/reload` or a new login. A cooldown CAB did not note (started without it, shared with another recipe, or lost when the game closed abruptly) is only known once its profession is open: open it before relying on **Max** or the purchase quote.

The ready alert, its sound, and the floating window are on by default. You can change them in **`/cab` → Transmutations**. The alert appears once per completed cooldown, including when a tracked cooldown finishes while you are logged out. For characters who know Alchemy, the window shows each transmutation’s icon and its time remaining or **Ready**, even when CAB is closed. Hover over the icon for the recipe and over the small bag for the reagents needed for one craft and their availability in your bags, bank or at vendors. Unlock the window to move it or resize it using the bottom-right handle. A wider window fits more recipes side by side, and the mouse wheel scrolls if rows extend below it. Size, position, lock and opacity are saved per character. After you make an Arcanite Bar on Forever build 71037, the other learned recipes that share its cooldown show the same countdown. Iron to Gold and Mithril to Truesilver each keep their own timer. Open Alchemy to check a cooldown marked **Unknown**.

## Download and updates

Get the ready-to-install addon and its updates from
**[CurseForge](https://www.curseforge.com/wow/addons/craftautobuy)**.
This GitHub repository hosts the source code, issue tracker and release notes.

- **CAB catalogue:** craftable recipes across your professions, favorites,
  search, bank and skill progression filters.
- **Plan, buy, craft:** account for vendor supplies and learned intermediate
  recipes. Purchases and crafting happen when you click their action buttons.
- **Stock v2:** bags and personal bank side by side, Components/All and profession
  filters, aligned inventory totals, storage capacity and bag upgrade estimates.
- **Preferences:** display settings and scroll positions saved per character;
  twelve supported languages.

Open your bank once to record its contents, then consult that snapshot away
from the bank. Bag upgrade estimates are simulations and do not move items.
If **Reading bank contents…** persists across visits after you removed a bank
bag that held reagents, equip a bag in that same slot. An empty bag is enough
for CAB to read the slot again.

| Chat command | What it does |
|---|---|
| `/cab config` | Opens the settings, just like `/cab`. |
| `/cab scan` | Rereads the recipes in your open profession window. |
| `/cab debug` | Prints the addon and game versions, selected recipe and catalogue counts. |
| `/cab vendor <itemID>` | Toggles whether CAB treats that item as a vendor supply for this character. Enter the item's positive whole-number ID; any other number changes nothing. |

[Documentation (French)](CraftAutoBuy/README.md) ·
[Release notes](https://github.com/aranud87/CraftAutoBuy/releases) ·
[Report a bug](https://github.com/aranud87/CraftAutoBuy/issues)

## Français

**[Téléchargement et mises à jour sur CurseForge](https://www.curseforge.com/wow/addons/craftautobuy)**

CraftAutoBuy facilite la préparation des crafts et la consultation du stock
dans **World of Warcraft: Forever**. Version **1.4.1**.

Les recettes se chargent en arrière-plan sur les builds Forever vérifiés.
Après une mise à jour du jeu en attente de vérification, les recettes
mémorisées restent disponibles. Ouvrez les métiers indiqués par CAB pour
actualiser leurs recettes.

Déposez les composants à la banque personnelle ou retirez les ingrédients
d’une recette depuis sa fiche CAB. Un clic sur la recette peut ouvrir son
métier. Chez le marchand, choisissez si le devis tient compte de la banque
et vérifiez les quantités et le prix avant l’achat.

Dans l’onglet CAB, l’icône de la recette affiche le nombre d’objets produits par fabrication quand il dépasse un. Si la quantité varie, l’icône indique une fourchette.
Le bouton **Créer × N** affiche le nombre de fabrications du prochain clic.
Pour un intermédiaire, l’infobulle indique la recette et le nombre de fabrications du prochain lot.
Dans l’onglet CAB, **Max** remplit la quantité prévue, jusqu’à **1 000 fabrications**
de la recette choisie. Ce plafond vaut aussi pour la quantité saisie à la main.

Pour une transmutation à recharge comme Fer en Or, CAB propose au plus une fabrication quand elle est prête. Sous le nom du métier, sa fiche indique la recharge qui suit une fabrication, avec la durée que donne le jeu. Tant que sa recharge est connue et en cours, elle compte pour zéro, même si vous consultez un autre métier. Cela vaut aussi pour les intermédiaires. Le métier ouvert fournit le nombre de charges des recettes qui en ont. CAB retient ces recharges pour ce personnage, y compris après un `/reload` ou une reconnexion. Une recharge qu’il n’a pas notée (lancée sans lui, partagée avec une autre recette, ou perdue lors d’un arrêt brutal du jeu) n’est connue qu’une fois son métier ouvert : ouvrez-le avant de vous fier à **Max** ou au devis d’achat.

L’alerte, le son et la fenêtre flottante sont activés par défaut. Vous pouvez les régler dans **`/cab` → Transmutations**. L’alerte apparaît une fois par recharge terminée, y compris à la reconnexion si une recharge suivie a expiré pendant votre absence. Sur un personnage qui connaît l’Alchimie, la fenêtre affiche l’icône de chaque transmutation et le temps restant ou **Prêt**, même quand CAB est fermé. Survolez l’icône pour voir la recette et le petit sac pour connaître les composants requis pour une fabrication et leur disponibilité en sacs, en banque ou chez un marchand. Déverrouillez la fenêtre pour la déplacer ou la redimensionner par le coin inférieur droit. Une fenêtre plus large place davantage de recettes côte à côte. La molette permet de voir les lignes du bas si elles débordent. La taille, la position, le verrouillage et l’opacité sont mémorisés par personnage. Après la fabrication d’une barre d’arcanite sur le build Forever 71037, les autres recettes apprises qui partagent sa recharge affichent le même décompte. Fer en Or et Mithril en Vrai-argent ont chacun leur propre minuteur. Ouvrez l’Alchimie pour vérifier une recharge indiquée **Inconnu**.

- **Catalogue CAB :** recettes fabricables de vos métiers, favoris, recherche
  et filtres Banque/Progression.
- **Préparer, acheter, fabriquer :** fournitures PNJ et recettes intermédiaires
  connues prises en compte. Les achats et crafts se lancent au clic.
- **Stock v2 :** sacs et banque personnelle en parallèle, filtres Composants/Tous
  et métier, inventaire aligné avec totaux, capacités et simulations de sacs.
- **Préférences :** affichage et défilement mémorisés par personnage,
  douze langues disponibles.

Ouvrez la banque une première fois pour enregistrer son contenu et consulter
ce relevé à distance. Les simulations de sacs ne déplacent aucun objet.
Si « Lecture de la banque en cours… » persiste à chaque visite après le retrait
d’un sac de banque qui contenait des composants, équipez un sac dans le même
emplacement. Un sac vide suffit pour que CAB puisse relire cet emplacement.

| Commande de discussion | Effet |
|---|---|
| `/cab config` | Ouvre les réglages, comme `/cab`. |
| `/cab scan` | Relit les recettes de votre métier ouvert. |
| `/cab debug` | Affiche les versions de l’addon et du jeu, la recette sélectionnée et les compteurs du catalogue. |
| `/cab vendor <ID>` | Active ou désactive le classement de l’objet comme fourniture de marchand pour ce personnage. Remplacez `<ID>` par le numéro entier positif de l’objet ; un autre nombre ne change rien. |

GitHub reste consacré au code source, aux signalements et aux changelogs.
Pour installer l'addon ou le mettre à jour, utilisez CurseForge.

[Documentation complète](CraftAutoBuy/README.md) ·
[Notes de version](https://github.com/aranud87/CraftAutoBuy/releases) ·
[Signaler un problème](https://github.com/aranud87/CraftAutoBuy/issues)
