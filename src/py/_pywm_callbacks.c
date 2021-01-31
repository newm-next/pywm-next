#include <Python.h>
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/util/log.h>
#include "wm/wm.h"
#include "wm/wm_layout.h"
#include "py/_pywm_callbacks.h"
#include "py/_pywm_view.h"

static struct _pywm_callbacks callbacks = { 0 };

/*
 * Helpers
 */
static bool call_bool(PyObject* callable, PyObject* args){
    PyObject *_result = PyObject_Call(callable, args, NULL);
    Py_XDECREF(args);

    int result = false;
    if(!_result || _result == Py_None || !PyArg_Parse(_result, "b", &result)){
        wlr_log(WLR_DEBUG, "Python error: Expected boolean return");
    }
    Py_XDECREF(_result);
    return result;
}

static void call_void(PyObject* callable, PyObject* args){
    PyObject *_result = PyObject_Call(callable, args, NULL);
    Py_XDECREF(args);

    if(!_result){
        wlr_log(WLR_DEBUG, "Python error: Exception thrown");
    }
    Py_XDECREF(_result);
}

/*
 * Callbacks
 */
static void call_layout_change(struct wm_layout* layout){
    if(callbacks.layout_change){
        PyGILState_STATE gil = PyGILState_Ensure();
        struct wlr_box* box = wlr_output_layout_get_box(layout->wlr_output_layout, NULL);
        PyObject* args = Py_BuildValue("(ii)", box->width, box->height);
        call_void(callbacks.layout_change, args);
        PyGILState_Release(gil);
    }
}

static bool call_key(struct wlr_event_keyboard_key* event, const char* keysyms){
    if(callbacks.key){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(iiis)", event->time_msec, event->keycode, event->state, keysyms);
        bool result = call_bool(callbacks.key, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static bool call_modifiers(struct wlr_keyboard_modifiers* modifiers){
    if(callbacks.modifiers){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(iiii)", modifiers->depressed, modifiers->latched, modifiers->locked, modifiers->group);
        bool result = call_bool(callbacks.modifiers, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static bool call_motion(double delta_x, double delta_y, uint32_t time_msec){
    if(callbacks.motion){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(idd)", time_msec, delta_x, delta_y);
        bool result = call_bool(callbacks.motion, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static bool call_motion_absolute(double x, double y, uint32_t time_msec){
    if(callbacks.motion_absolute){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(idd)", time_msec, x, y);
        bool result = call_bool(callbacks.motion_absolute, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static bool call_button(struct wlr_event_pointer_button* event){
    if(callbacks.button){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(iii)", event->time_msec, event->button, event->state);
        bool result = call_bool(callbacks.button, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static bool call_axis(struct wlr_event_pointer_axis* event){
    if(callbacks.axis){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(iiidi)", event->time_msec, event->source, event->orientation,
                event->delta, event->delta_discrete);
        bool result = call_bool(callbacks.axis, args);
        PyGILState_Release(gil);
        return result;
    }

    return false;
}

static void call_init_view(struct wm_view* view){
    if(callbacks.init_view){
        long handle = _pywm_views_add(view);
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(l)", handle);
        call_void(callbacks.init_view, args);
        PyGILState_Release(gil);
    }
}

static void call_destroy_view(struct wm_view* view){
    if(callbacks.destroy_view){
        long handle = _pywm_views_remove(view);
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(l)", handle);
        call_void(callbacks.destroy_view, args);
        PyGILState_Release(gil);
    }
}

static void call_view_focused(struct wm_view* view){
    if(callbacks.view_focused){
        long handle = _pywm_views_get_handle(view);
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("(l)", handle);
        call_void(callbacks.view_focused, args);
        PyGILState_Release(gil);
    }
}

static void call_ready(){
    if(callbacks.ready){
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject* args = Py_BuildValue("()");
        call_void(callbacks.ready, args);
        PyGILState_Release(gil);
    }
}

/*
 * Public interface
 */
void _pywm_callbacks_init(){
    get_wm()->callback_layout_change = &call_layout_change;
    get_wm()->callback_key = &call_key;
    get_wm()->callback_modifiers = &call_modifiers;
    get_wm()->callback_motion = &call_motion;
    get_wm()->callback_motion_absolute = &call_motion_absolute;
    get_wm()->callback_button = &call_button;
    get_wm()->callback_axis = &call_axis;
    get_wm()->callback_init_view = &call_init_view;
    get_wm()->callback_destroy_view = &call_destroy_view;
    get_wm()->callback_view_focused = &call_view_focused;
    get_wm()->callback_ready = &call_ready;
}

PyObject** _pywm_callbacks_get(const char* name){
    if(!strcmp(name, "motion")){
        return &callbacks.motion;
    }else if(!strcmp(name, "motion_absolute")){
        return &callbacks.motion_absolute;
    }else if(!strcmp(name, "button")){
        return &callbacks.button;
    }else if(!strcmp(name, "axis")){
        return &callbacks.axis;
    }else if(!strcmp(name, "key")){
        return &callbacks.key;
    }else if(!strcmp(name, "modifiers")){
        return &callbacks.modifiers;
    }else if(!strcmp(name, "init_view")){
        return &callbacks.init_view;
    }else if(!strcmp(name, "destroy_view")){
        return &callbacks.destroy_view;
    }else if(!strcmp(name, "view_focused")){
        return &callbacks.view_focused;
    }else if(!strcmp(name, "layout_change")){
        return &callbacks.layout_change;
    }else if(!strcmp(name, "ready")){
        return &callbacks.ready;
    }

    return NULL;
}
