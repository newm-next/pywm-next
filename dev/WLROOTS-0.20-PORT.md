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
| `delta` | `double`) | `double` | **conservé**, pas fusionné avec `delta_discrete` |
| `delta_discrete` | `int32_t` | `int32_t` | **conservé** → les unités de scroll ne changent pas |

0.20 ajoute `relative_direction` à la structure ; elle n'est pas transmise à
Python (elle ne l'était pas en 0.16) et est passée telle quelle à
`wlr_seat_pointer_notify_axis()`.

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
| Scroll | `_pywm_callbacks.c`, `wm_seat.c` | `delta` **et** `delta_discrete` conservés → aucune conversion d'unité ; `relative_direction` ajoutée à l'appel `wlr_seat_pointer_notify_axis()` uniquement. |

## 3. Écarts fonctionnels assumés

1. **Curseur racine Xwayland** — `wlr_xwayland_set_cursor()` exige désormais un
   `struct wlr_buffer`, et wlroots a supprimé le helper public qui construisait
   ce buffer depuis une image xcursor. Le thème est passé à Xwayland par
   `XCURSOR_THEME` avant son démarrage : rendu identique, code différent.
2. **Widgets cairo** — `wlr_texture_write_pixels()` supprimé. Les pixels sont
   ré-uploadés par recréation de la texture (`wlr_texture_from_pixels`). Rendu
   identique, coût d'allocation à chaque mise à jour de widget.

## 4. À vérifier sur matériel (non testable sur le VPS : pas de /dev/dri)

1. Démarrage du compositeur + `_pywm` importable ; newm-next se lance et affiche.
2. Sortie DRM : mode, scale HiDPI, rotation ; pas de frame perdue en continu.
3. Damage : fenêtres qui bougent/scrollent sans traînée ni zone figée ;
   `constant_damage_mode` (animation) sans clignotement.
4. Rendu custom : coins arrondis, blur, opacité, shaders de widget — identiques
   à la version 0.16 (point le plus risqué).
5. Curseur : thème, curseur client (`set_cursor`), curseur logiciel sur les
   sorties sans curseur matériel.
6. Gamma : `wlr-gamma-control` (gammastep/redshift) applique bien la rampe.
7. Entrées : clavier + modificateurs, scroll (vitesse inchangée), gestes
   touchpad, changement de VT (Ctrl-Alt-F1…F12).
8. Xwayland : fenêtre X11, décoration, maximize, curseur racine.
