# Port pywm → wlroots 0.20.2 — notes de portage

Branche `port/wlroots-0.20.2`, base `wlroots-update` (`9489297`).
Objectif : compiler contre wlroots 0.20.2 **sans changer le fonctionnement**.

## 1. Correspondance champ par champ (C → Python)

Ces structures sont lues directement dans `src/py/_pywm_callbacks.c` et
transmises à newm via `Py_BuildValue`. Le format ne change pas ; seul le nom du
type change.

### Clavier — `call_key`, format `(iiis)`

| Champ pywm 0.16 | 0.16 (ligne d'en-tête) | 0.20.2 (ligne d'en-tête) | Type / unité |
|---|---|---|---|
| `event->time_msec` | `struct wlr_event_keyboard_key.time_msec` | `struct wlr_keyboard_key_event.time_msec` | `uint32_t` ms, identique |
| `event->keycode` | idem, `keycode` | idem, `keycode` | `uint32_t` evdev (+8 appliqué côté pywm), identique |
| `event->state` | `enum wlr_key_state` | `enum wl_keyboard_key_state` | 0 = released, 1 = pressed, identique |

### Bouton — `call_button`, format `(iii)`

| Champ pywm 0.16 | 0.16 | 0.20.2 | Type / unité |
|---|---|---|---|
| `time_msec` | `struct wlr_event_pointer_button` | `struct wlr_pointer_button_event` | `uint32_t` ms |
| `button` | idem | idem | `uint32_t` code evdev |
| `state` | `enum wlr_button_state` | `enum wl_pointer_button_state` | 0 = released, 1 = pressed |

### Axe — `call_axis`, format `(iiidi)`

| Champ pywm 0.16 | 0.16 | 0.20.2 | Type / unité |
|---|---|---|---|
| `time_msec` | `struct wlr_event_pointer_axis` | `struct wlr_pointer_axis_event` | `uint32_t` ms |
| `source` | `enum wlr_axis_source` | `enum wl_pointer_axis_source` | identique (wheel/finger/continuous) |
| `orientation` | `enum wlr_axis_orientation` | `enum wl_pointer_axis` | identique (vertical/horizontal) |
| `delta` | `double` | `double` | identique, `get_axis_value()` n'a pas changé |
| `delta_discrete` | `int32_t`, **±1 par cran** | `int32_t`, **multiple de 120 (v120)** | ramené à ±1 par cran côté pywm, voir ci-dessous |

0.20 ajoute `relative_direction` à la structure ; elle n'est pas transmise à
Python (elle ne l'était pas en 0.16) et est passée telle quelle à
`wlr_seat_pointer_notify_axis()`.

### Scroll : `delta_discrete` change d'unité (vérifié ligne par ligne)

| | 0.16 (`subprojects/wlroots` de master) | 0.20.2 |
|---|---|---|
| abonnement libinput | `backend/libinput/events.c:271` : `LIBINPUT_EVENT_POINTER_AXIS` seul | `backend/libinput/events.c:169-171` : `POINTER_AXIS` **ignoré** (« must be ignored in favour of the SCROLL_* events »), `:172` `POINTER_SCROLL_WHEEL` |
| valeur discrète | `backend/libinput/pointer.c:140-141` : `libinput_event_pointer_get_axis_value_discrete()` brut, **±1 par cran** | `backend/libinput/pointer.c:178-179` : `get_scroll_value_v120()`, **120 par cran** ; l'ancien chemin `:137-139` multiplie par `WLR_POINTER_AXIS_DISCRETE_STEP` mais n'est plus atteint depuis libinput |
| constante | absente | `include/wlr/types/wlr_pointer.h:74` : `#define WLR_POINTER_AXIS_DISCRETE_STEP 120` |

Sans correction, newm recevait `delta_discrete` 120 fois trop grand. Le
correctif est dans `src/py/_pywm_callbacks.c` (`wm_axis_discrete_value()`) :

- accumulateur par pointeur et par orientation (`remainder[2]`), division
  **entière** par `WLR_POINTER_AXIS_DISCRETE_STEP`, reste conservé ;
- remise à zéro quand la source n'est pas `WL_POINTER_AXIS_SOURCE_WHEEL` ou
  quand le sens s'inverse ;
- `delta` n'est pas touché, `wm_seat.c` transmet toujours la valeur brute à
  `wlr_seat_pointer_notify_axis()`, le format `(iiidi)` ne change pas.

Conséquences attendues : molette classique = ±120 par cran → ±1 exactement
comme avant ; molette haute résolution = plusieurs événements de 15 → un cran
seulement quand le cumul atteint 120 (sans accumulateur, chaque fraction
tronquée donnerait 0 et la molette ne produirait plus aucun cran). Écart
assumé : une molette haute résolution produit maintenant plusieurs petits
`delta` par cran au lieu d'un seul, la somme est identique.

### Gestes — `call_gesture_*`

| Événement 0.16 | 0.20.2 | Champs transmis |
|---|---|---|
| `wlr_event_pointer_swipe_begin` | `wlr_pointer_swipe_begin_event` | `time_msec`, `fingers` |
| `wlr_event_pointer_swipe_update` | `wlr_pointer_swipe_update_event` | `time_msec`, `fingers`, `dx`, `dy` |
| `wlr_event_pointer_swipe_end` | `wlr_pointer_swipe_end_event` | `time_msec`, `cancelled` |
| `wlr_event_pointer_pinch_begin` | `wlr_pointer_pinch_begin_event` | `time_msec`, `fingers` |
| `wlr_event_pointer_pinch_update` | `wlr_pointer_pinch_update_event` | `time_msec`, `fingers`, `dx`, `dy`, `rotation`, `scale` |
| `wlr_event_pointer_pinch_end` | `wlr_pointer_pinch_end_event` | `time_msec`, `cancelled` |
| `wlr_event_pointer_hold_begin` | `wlr_pointer_hold_begin_event` | `time_msec`, `fingers` |
| `wlr_event_pointer_hold_end` | `wlr_pointer_hold_end_event` | `time_msec`, `cancelled` |

Tous les noms de champs sont identiques ; seul `device` disparaît au profit de
`pointer` (non utilisé par pywm).

### Mouvement — `call_motion`, format `(idddd)`

Pas de structure lue : `wm_cursor.c` calcule `delta_x/delta_y` lui-même.
`event->device` (0.16) devient `&event->pointer->base` pour `wlr_cursor_move`.

## 2. Points sensibles

| Point | Fichier | Ce qui change |
|---|---|---|
| Damage | `wm_output.c`, `wm_layout.c`, `wm_output.h` | `wlr_output_damage` → `struct wlr_damage_ring` possédé par le compositeur ; `wlr_damage_ring_rotate_buffer()` après `wlr_output_begin_render_pass()`. Le signal `frame` vient de `wlr_output->events.frame`. |
| Sorties | `wm_output.c` | `wlr_output_enable/set_mode/set_custom_mode/set_scale/set_transform/commit` → un seul `struct wlr_output_state` + `wlr_output_commit_state()`. Un seul commit au lieu de deux (mode/transform puis scale) : effet net identique. |
| Gamma | `wm_server.c` | `wlr_output_set_gamma()` supprimé : le LUT est appliqué par le compositeur sur `events.set_gamma` via `wlr_gamma_control_v1_apply()` + commit. |
| Matrices | `src/wm/wm_matrix.c`, `include/wm/wm_matrix.h` | `wlr_matrix_*` n'est plus exporté : helpers 3×3 copiés à l'identique de `util/matrix.c` de wlroots (mêmes formules), préfixés `wm_`. |
| Rendu GLES | `wm_renderer.c` | `wlr_renderer_begin/end/clear/scissor`, `wlr_render_pass` → `wlr_output_begin_render_pass()` / `wlr_render_pass_submit()`. Le FBO du buffer courant s'obtient par `wlr_gles2_renderer_get_buffer_fbo()` (l'ancien `gles2_renderer->current_buffer` a disparu). La projection est recalculée localement. Le scissor est fait en GL direct (`glScissor`) avec le même flip vertical. Shaders inchangés. |
| Curseurs | `wm_cursor.c`, `wm_renderer.c` | `wlr_cursor_set_image(NULL,…)` → `wlr_cursor_unset_image()` ; `wlr_xcursor_manager_set_cursor_image()` → `wlr_cursor_set_xcursor()` ; `wlr_output_render_software_cursors()` → `wlr_output_add_software_cursors_to_render_pass()` (avant `wlr_render_pass_submit()`). |
| Scroll | `_pywm_callbacks.c`, `wm_seat.c` | `delta_discrete` est en unités v120 (120 par cran) en 0.20 : accumulateur + division entière dans `wm_axis_discrete_value()` pour retrouver ±1 par cran ; `delta` et `wm_seat.c` inchangés ; `relative_direction` ajoutée à `wlr_seat_pointer_notify_axis()` uniquement. |

## 3. Écarts fonctionnels assumés

1. **Curseur racine Xwayland** — `wlr_xwayland_set_cursor()` exige désormais un
   `struct wlr_buffer`, et wlroots a supprimé le helper public qui construisait
   ce buffer depuis une image xcursor. Le thème est passé à Xwayland par
   `XCURSOR_THEME` avant son démarrage : rendu identique, code différent.
2. **Widgets cairo** — `wlr_texture_write_pixels()` supprimé. Les pixels sont
   ré-uploadés par recréation de la texture (`wlr_texture_from_pixels`). Rendu
   identique, coût d'allocation à chaque mise à jour de widget.

## 4. Cycle de vie des surfaces (0.18+) — plantages corrigés après le premier test réel

Le port compilait mais ne pouvait afficher aucune fenêtre : ces changements de
cycle de vie ne cassent pas la compilation, seulement l'exécution.

| Sujet | Symptôme | 0.20.2 |
|---|---|---|
| Rôle xdg | `wm_server.c` écoutait `wlr_xdg_shell.events.new_surface`, émis **avant** l'attribution du rôle : `surface->toplevel` vaut NULL et `wm_view_xdg_init` le déréférence (SIGSEGV à la première fenêtre) | écoute `events.new_toplevel` (`include/wlr/types/wlr_xdg_shell.h:27`) ; le payload est un `wlr_xdg_toplevel*`, la vue repart de `toplevel->base`. Les popups arrivent toujours par `new_popup` de la vue parente. |
| Première configuration xdg | la fenêtre ne mappe jamais | `wlr_xdg_surface.initial_commit` (`types/xdg_shell/wlr_xdg_surface.c:326-327`) : sur le premier commit, `wm_view_xdg.c` / popups appellent `wlr_xdg_surface_schedule_configure()` (`include/wlr/types/wlr_xdg_shell.h:591`). |
| Première configuration layer-shell | **SIGABRT** : `wlr_layer_surface_v1_configure()` commence par `assert(surface->initialized)` (`types/wlr_layer_shell_v1.c:316-318`) et pywm l'appelait sans condition | la taille demandée par le layout est mémorisée (`requested_width/height`) tant que `!initialized`, puis envoyée sur `initial_commit` (`types/wlr_layer_shell_v1.c:399-400` met `initialized = true` avant d'émettre le commit). |
| Requêtes sur une fenêtre masquée | **SIGABRT** : les setters (`set_size`, `set_tiled`, `set_resizing`, `set_fullscreen`, `set_maximized`, `set_activated`) appellent tous `wlr_xdg_surface_schedule_configure()`, qui exige une surface initialisée ; or `reset_xdg_surface()` remet `initialized = false` à chaque unmap, alors que newm continue de piloter la vue | `types/xdg_shell/wlr_xdg_toplevel.c:598` → `types/xdg_shell/wlr_xdg_surface.c:168` (assert) ; `reset_xdg_surface` : `wlr_xdg_surface.c:28-30`, appelé sur unmap `:320-321` | état miroir dans `struct wm_view_xdg::pending` (taille, flottant, redimensionnement, plein écran, maximisation, focus), rejoué dans `wm_view_xdg_apply_pending()` au `initial_commit` suivant ; la fermeture des popups à la désactivation reste immédiate |
| Décorations xdg | `wlr_xdg_toplevel_decoration_v1_set_mode()` finit aussi par `schedule_configure()` (`types/wlr_xdg_decoration_v1.c:56-57`) ; les clients créent leur décoration **avant** le premier commit, donc le mode était demandé sur une surface non initialisée → SIGABRT | mode mémorisé dans `pending.deco_mode`, appliqué au `initial_commit` ; `shows_csd` continue d'être calculé au même moment |
| Popups | `wlr_xdg_popup_unconstrain_from_box()` finit par `schedule_configure()` (`types/xdg_shell/wlr_xdg_popup.c`) et était appelé à la création du popup → SIGABRT | positionnement déplacé au premier commit du popup (xdg **et** layer) ; le positionnement envoyant lui-même la configuration, l'appel séparé à `schedule_configure()` a été supprimé |
| Destruction des vues | **SIGABRT** à la fermeture de la première fenêtre : wlroots détruit l'objet rôle **avant** l'xdg_surface et vérifie juste après que toutes les listes de listeners du toplevel sont vides ; pywm n'écoutait que `xdg_surface->events.destroy`, donc ses listeners `request_*` étaient encore là | `destroy_xdg_surface_role_object()` → `destroy_xdg_toplevel()` (`wlr_xdg_surface.c:484-497`) qui émet puis contrôle (`wlr_xdg_toplevel.c:546-557`) et libère (`:560-562`) ; même schéma pour les popups (`wlr_xdg_popup.c:476-477`) | destruction déclenchée sur `toplevel->events.destroy` (et `wlr_xdg_popup->events.destroy`) ; le teardown retire aussi le listener posé sur `xdg_surface`, ce qui évite une seconde destruction ; `wl_signal_emit_mutable()` autorise le retrait pendant l'émission |
| Programmations d'images | les clients ne reçoivent plus `wl_surface.frame` : le compositeur ne redessine que sur événement, les clients se figent | en 0.16 `wlr_output_damage` écoutait `wlr_output.events.damage` et `needs_frame` et programmailt l'image à chaque ajout de damage ; depuis 0.17 c'est au compositeur | `wm_output_damage()` / `wm_output_damage_whole()` ajoutent au ring **et** appellent `wlr_output_schedule_frame()` ; la sortie écoute `events.damage` (payload `struct wlr_output_event_damage`) et `events.needs_frame`, retirés à la destruction |
| Xwayland | `surface->surface` est NULL à la création : les `wl_signal_add` sur `map`/`unmap` déréférencent NULL | `wlr_xwayland_surface.surface` n'est valide qu'entre `associate` et `dissociate` (`include/wlr/xwayland/xwayland.h:126-128`) : les listeners de surface sont posés sur `associate` et retirés sur `dissociate`. |

## 5. À vérifier sur matériel (non testable sur le VPS : pas de /dev/dri)

1. Démarrage du compositeur + `_pywm` importable ; newm-next se lance et affiche.
2. Sortie DRM : mode, scale HiDPI, rotation ; pas de frame perdue en continu.
3. Damage : fenêtres qui bougent/scrollent sans traînée ni zone figée ;
   `constant_damage_mode` (animation) sans clignotement.
4. Rendu custom : coins arrondis, blur, opacité, shaders de widget — identiques
   à la version 0.16 (point le plus risqué).
5. Curseur : thème, curseur client (`set_cursor`), curseur logiciel sur les
   sorties sans curseur matériel.
6. Gamma : `wlr-gamma-control` (gammastep/redshift) applique bien la rampe.
7. Entrées : clavier + modificateurs, gestes touchpad, changement de VT
   (Ctrl-Alt-F1…F12). Scroll avec **trois** périphériques — molette à crans
   classique, molette haute résolution, touchpad deux doigts — même vitesse
   qu'avant, pas de cran qui « colle », et le sens s'inverse proprement.
8. Xwayland : ouvrir une application X11 (fenêtre + décoration), maximize, curseur racine.
