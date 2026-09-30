#include <jni.h>
#include "ltatarev_reactnativecloudkitOnLoad.hpp"

#include <fbjni/fbjni.h>


JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::ltatarev_reactnativecloudkit::registerAllNatives();
  });
}