# Installer pywm + newm (wlroots 0.20.2) sur Arch Linux

Archive : `pywm-wlroots-0.20.2-arch.tar.gz`. Elle contient trois arbres :

| Répertoire | Contenu | Commit |
|---|---|---|
| `pywm-next/` | compositeur + module Python `_pywm` | `3b2b9a7` (branche `wlroots-update`) |
| `pywm-next/subprojects/wlroots/` | wlroots 0.20.2 (sous-module) | `d783533`, tag `0.20.2` |
| `newm-next/` | gestionnaire de fenêtres | `dd9097f` |

Le binaire **doit être compilé sur la machine cible** : le Python d'Arch courant
est 3.14, celui du VPS 3.13, et `_pywm` est un module d'extension C dont l'ABI
dépend de la version de Python. Aucun binaire précompilé n'est fourni.

## 1. Paquets pacman

Noms et versions vérifiés dans les dépôts `core`/`extra` au moment de la
livraison (`meson`, `ninja`, `pkgconf`, `wayland 1.26.0`,
`wayland-protocols 1.50`, `libdrm 2.4.134`, `libxkbcommon 1.13.2`,
`pixman 0.46.4`, `libinput 1.32.0`, `mesa 26.3.1`, `python 3.14`,
`python-gobject 3.58.1`, `xorg-xwayland 24.1.15`) :

```sh
sudo pacman -S --needed base-devel git meson ninja pkgconf python python-pip \
    wayland wayland-protocols libdrm libxkbcommon pixman libinput mesa \
    libxcb xcb-util-wm xcb-util-renderutil libxfixes libxrender \
    libliftoff xorg-xwayland seatd libdisplay-info \
    python-numpy python-cairo python-evdev python-imageio python-psutil \
    python-pam python-dasbus python-gobject
```

Pourquoi ces paquets « en plus » — ils manquent tous à un premier essai, et
`meson setup` s'arrête dessus (constaté en testant dans un chroot Arch, pas
déduit) :

- `xorg-xwayland` : fournit `xwayland.pc`, exigé par wlroots quand le support
  X11 est activé ;
- `libliftoff` : requis par le backend DRM ;
- `xcb-util-renderutil` : requis par le backend X11 de wlroots ;
- `libxfixes` / `libxrender` : dépendances de `xorg-xwayland` ;
- `seatd` (fournit `libseat`) : requis par `wlroots/backend/session`.
  Sans lui : `ERROR: Dependency 'libseat' is required but not found` ;
- `libdisplay-info` : requis par le backend DRM.
  Sans lui : `ERROR: Dependency 'libdisplay-info' is required but not found`.

`python-pyfiglet` et `python-thefuzz` (dans `newm-next/requirements.txt`)
**n'existent pas dans les dépôts officiels** : ils s'installent par pip, dans
le venv.

## 2. Compiler

Les versions d'Arch (`wayland 1.26`, `libdrm 2.4.134`, `xkbcommon 1.13.2`,
`pixman 0.46.4`) satisfont toutes le minimum de wlroots 0.20.2 : meson utilise
donc les bibliothèques **système** et ne télécharge aucun `wrap`. C'est ce que
vérifie `--wrap-mode=nofallback` ci-dessous.

```sh
cd pywm-next
meson setup build --wrap-mode=nofallback \
    -Dwlroots:examples=false \
    -Dwlroots:backends=drm,libinput \
    -Dwlroots:renderers=gles2 \
    -Dwlroots:allocators=gbm,udmabuf \
    -Dwlroots:xwayland=enabled
ninja -C build
```

**Les options `-Dwlroots:…` ne sont pas facultatives.** Avec les valeurs par
défaut, meson configure wlroots *sans* backend libinput
(`libinput-backend : NO`) ; la compilation des sources passe, mais l'édition de
liens de `pywm` et de `_pywm…so` laisse des symboles non résolus
(`wlr_input_device_is_libinput`, `wlr_libinput_get_device_handle`) et le module
refuse de s'importer. C'est un échec silencieux : `meson setup` est vert, et
seul l'import le révèle.

Artefacts attendus : `build/pywm` et `build/_pywm.cpython-314-x86_64-linux-gnu.so`.

**Ne pas ajouter `-Db_ndebug=true`** (ni `--buildtype=release`, ni passer
`NDEBUG`) : pywm appelle `wlr_egl_make_current()` à l'intérieur d'`assert(...)`
(`src/wm/wm_renderer.c`). Les assertions sont donc porteuses d'effet de bord ;
les supprimer casse le rendu sans erreur de compilation. Le type de build par
défaut (`debug`) est correct, et `setup.py` fait exactement `meson build` +
`ninja -C build`, donc `pip install .` conserve les assertions.

## 3. Installer dans un venv

Arch refuse `pip install` hors environnement virtuel (PEP 668). Le venv doit
voir les paquets Python de pacman (`gi`, `cairo`, `numpy`…) d'où
`--system-site-packages` :

```sh
python -m venv --system-site-packages ~/.local/share/pywm-venv
. ~/.local/share/pywm-venv/bin/activate

pip install pyfiglet thefuzz                    # absents des dépôts Arch
cd pywm-next && pip install --no-build-isolation .
cd ../newm-next && pip install --no-build-isolation .
```

`--no-build-isolation` est nécessaire : `setup.py` de pywm appelle `meson` et
`ninja` du système, que pip n'installerait pas dans un environnement isolé.

Vérification rapide :

```sh
python -c "import _pywm; print(sorted(dir(_pywm)))"
# ['damage', 'debug_performance', 'register', 'run']
python -c "import pywm, newm; print(pywm.PyWM, newm.Layout)"
```

## 4. Lancer

Depuis un TTY (VT libre), **pas** depuis une session X11/Wayland existante :

```sh
~/.local/share/pywm-venv/bin/start-newm -d
```

`start-newm` place le journal dans `$HOME/.cache/newm/newm_log` et archive le
précédent en `newm_log.old.<date>`. Le flag `-d` active les traces détaillées.

Si le compositeur refuse de démarrer : vérifier que le TTY courant est libre,
que l'utilisateur appartient aux groupes `video` et `input`, et que
`/dev/dri/card0` est accessible.

## 5. Retour arrière

Rien n'est écrasé hors du venv :

```sh
deactivate
rm -rf ~/.local/share/pywm-venv
```

Pour revenir à l'ancienne installation, relancer l'ancien `start-newm` (ou
l'ancien venv) : les deux versions cohabitent tant que la nouvelle n'a pas
remplacé l'appel dans votre configuration de démarrage.

## 6. Journaux

| Quoi | Où |
|---|---|
| newm / pywm | `~/.cache/newm/newm_log` (+ `newm_log.old.*`) |
| build pywm | sortie de `ninja -C build` |
| meson | `pywm-next/build/meson-logs/meson-log.txt` |

Les points à contrôler à l'écran sont dans `TEST-HARDWARE.md`, à la racine de
l'archive.
