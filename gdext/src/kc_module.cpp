// kc_module.cpp —— GDExtension 入口：注册四个类 + 库初始化/反初始化
#include "kc_guard.h"
#include "kc_hook_ext.h"
#include "kc_store_ext.h"
#include "kc_window.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

// >>> zone:human
using namespace godot;

static void initialize_keycount_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(KeyCountHook);
	GDREGISTER_CLASS(KeyCountWindow);
	GDREGISTER_CLASS(KeyCountStore);
	GDREGISTER_CLASS(KeyCountGuard);
	kc_ext::remember_prev_foreground();
}

static void uninitialize_keycount_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT keycount_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_keycount_module);
	init_obj.register_terminator(uninitialize_keycount_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
// <<<
