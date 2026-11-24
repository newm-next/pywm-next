# Test matériel — pywm + newm sur wlroots 0.20.2

Rien de ce qui suit n'a pu être exécuté sur le VPS de build : pas de
`/dev/dri`, et `/dev/udmabuf` réservé au groupe `kvm`. Le compositeur ne peut
pas démarrer là-bas. **Votre machine est la seule validation de cette liste.**

Tout tourne autour d'une seule question : *est-ce que ça se voit à l'écran ?*
Pour chaque point, la colonne « à voir » décrit le symptôme d'une régression.

Avant de commencer :

```sh
~/.local/share/pywm-venv/bin/start-newm -d
```

`$HOME/.cache/newm/newm_log` doit contenir les lignes de démarrage de pywm sans
`ERROR`. Gardez ce fichier : en cas de problème, c'est la pièce à joindre.

## Ordre de test

Trois étapes, dans cet ordre : chacune exerce un code différent du portage, et
s'arrêter à la première qui échoue donne un diagnostic net.

1. **Le panneau apparaît** (layer-shell, première configuration au commit) ;
2. **une fenêtre Wayland se mappe** (`new_toplevel`, surfaces xdg) ;
3. **une application X11 s'ouvre** (cycle associate/dissociate de Xwayland).

Si l'étape 1 échoue, le compositeur meurt avant tout affichage : c'est
layer-shell. Si l'étape 2 le tue, c'est le cycle de vie des surfaces xdg. Si
seule l'étape 3 échoue, c'est Xwayland seul.

## 1. Démarrage

| À faire | À voir |
|---|---|
| Lancer `start-newm -d` depuis un TTY | l'écran passe en noir puis affiche le fond newm ; aucune erreur Wayland dans le journal |
| `python -c "import pywm._pywm"` dans le venv | aucune exception (le module se charge) |

Régression = le compositeur sort immédiatement, ou le journal affiche
`undefined symbol` / `failed to open backend`.

## 2. Sortie DRM

| À faire | À voir |
|---|---|
| Écran principal, résolution native | image nette, pas de bande noire inattendue |
| Écran HiDPI avec `scale = 2` | interface à la bonne taille, pas de flou ni de double rendu |
| Rotation (`wlr-randr --output … --transform 90`) | tout pivote, souris cohérente avec l'image |
| Laisser tourner 5 minutes avec une horloge animée | aucune frame perdue, pas de saccade régulière |

Régression = mode non appliqué, moitié de l'écran figée, ou saccade périodique.

## 3. Damage (le plus susceptible de « traîner »)

| À faire | À voir |
|---|---|
| Déplacer une fenêtre rapidement | aucune traînée, aucun rectangle résiduel |
| Scroller une page longue | pas de zone figée en haut/bas |
| Ouvrir/fermer une fenêtre sous une autre | rien ne reste à l'écran |
| `constant_damage_mode` (animation de fond) | animation fluide, pas de clignotement |

Régression = traînées, rectangles figés, ou scintillement : c'est
`wlr_damage_ring` mal alimenté.

## 4. Cycle de vie des fenêtres (masquer / réafficher)

C'est le scénario qui a motivé les garde-fous du correctif : une fenêtre masquée
par son application perd son statut « initialisée » côté wlroots, et toute
commande de newm (taille, focus, plein écran) arrivée à ce moment doit être
mise en attente puis appliquée au retour, sans tuer le compositeur.

| À faire | À voir |
|---|---|
| Ouvrir un dialogue, le masquer (fermeture de la fenêtre parente ou `Super-q`), puis le réafficher | la fenêtre revient à sa place et à sa taille, le compositeur ne meurt pas |
| Pendant qu'une fenêtre est masquée, changer le focus vers une autre fenêtre | rien ne plante ; au retour, la fenêtre réapparaît avec la taille demandée |
| Masquer une fenêtre, la réafficher, puis la passer en plein écran | plein écran correct, pas de géométrie héritée de l'état précédent |
| Masquer puis réafficher plusieurs fois de suite | toujours la même géométrie, aucune dérive |

Régression = SIGABRT/SIGSEGV au moment du réaffichage ou du changement de
focus, fenêtre qui revient avec une taille d'il y a dix minutes, ou `configure`
en boucle dans le journal.

## 5. Rendu custom (risque le plus élevé)

| À faire | À voir |
|---|---|
| Fenêtre normale | coins arrondis, ombre si configurée, **sans inversion haut/bas** |
| Fenêtre en focus vs non focus | opacité/teinte correctes |
| `blur` activé sur une fenêtre | flou derrière la fenêtre, pas un aplat noir |
| Widget cairo (barre/overlay) | texte net, pas d'image déchirée, pas de clignotement |
| Fenêtre redimensionnée | le contenu suit, sans étirement |

Régression = tout à l'envers (projection inversée), noir, ou texte brouillé.
C'est le seul point où le portage a réécrit du code GL.

## 6. Curseur

| À faire | À voir |
|---|---|
| Survol du fond | curseur du thème (pas une flèche X11 par défaut) |
| Survol d'une fenêtre qui définit son curseur | le curseur change (texte, redimensionnement) |
| Fenêtre X11 | curseur correct, thème identique au reste |
| Sortie sans curseur matériel (si applicable) | curseur logiciel visible et fluide |

Régression = curseur invisible, figé, ou thème différent sur Xwayland —
voir l'écart assumé n°1 plus bas.

## 7. Gamma

```sh
gammastep -O 3500     # ou redshift
```
| À voir |
|---|
| la teinte de l'écran change progressivement, puis revient à la normale à l'arrêt |

Régression = aucune effet : wlroots 0.20 a supprimé `wlr_output_set_gamma()`,
la rampe passe maintenant par `events.set_gamma`.

## 8. Entrées

| À faire | À voir |
|---|---|
| Taper dans une fenêtre | caractères corrects, accents et touches mortes OK |
| Modificateurs (Maj, Ctrl, AltGr) | aucun blocage, pas de modificateur « collé » |
| Gestes touchpad 3/4 doigts configurés | déclenchent bien les actions newm |
| Ctrl-Alt-F1 … F12 | changement de VT puis retour au compositeur sans crash |

### Scroll — trois périphériques, à tester séparément

| Périphérique | À voir |
|---|---|
| Molette à crans classique | 1 cran = 1 cran, même vitesse qu'avant le portage |
| Molette haute résolution | le défilement ne « colle » pas au premier cran ; plusieurs petits mouvements s'additionnent jusqu'à un cran complet |
| Touchpad deux doigts | défilement continu et fluide, aucun cran parasite |

Dans les trois cas, inverser le sens en cours de geste doit repartir
proprement, sans cran fantôme. Si le scroll est ~120× trop rapide, la
conversion v120 n'a pas été appliquée ; si la molette haute résolution ne
produit plus aucun cran, l'accumulateur est cassé.

## 9. Xwayland

| À faire | À voir |
|---|---|
| Lancer une application X11 (`xterm`, GIMP…) | la fenêtre s'affiche, se déplace, se maximise |
| Décorations côté serveur | présentes si `encourage_csd` est désactivé |
| Curseur au-dessus de la fenêtre X11 | correct (écart assumé n°1) |

## Écarts assumés (comportement attendu, pas un bug)

1. **Curseur racine Xwayland** — `wlr_xwayland_set_cursor()` exige désormais un
   `wlr_buffer` et wlroots a supprimé le helper qui le construisait depuis une
   image xcursor. Le thème est passé par `XCURSOR_THEME` avant le démarrage de
   Xwayland. Conséquence visible possible : le curseur au-dessus des fenêtres
   X11 peut différer légèrement du reste.
2. **Widgets cairo** — `wlr_texture_write_pixels()` a été supprimé : les pixels
   sont ré-uploadés en recréant la texture. Rendu identique, mais une allocation
   par mise à jour de widget. À surveiller si vous avez un widget animé en
   permanence : consommation CPU/mémoire plus élevée qu'avant.

## Ce qu'il faut renvoyer en cas de problème

1. `$HOME/.cache/newm/newm_log` (et `newm_log.old.*` du lancement précédent) ;
2. le point de la liste qui échoue, avec ce que vous voyez à l'écran ;
3. la sortie de `wlr-randr` si le problème concerne une sortie ;
4. `echo $XDG_SESSION_TYPE` et le modèle de GPU.
