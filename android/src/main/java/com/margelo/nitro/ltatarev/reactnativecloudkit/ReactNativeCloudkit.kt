package com.margelo.nitro.ltatarev.reactnativecloudkit
  
import com.facebook.proguard.annotations.DoNotStrip

@DoNotStrip
class ReactNativeCloudkit : HybridReactNativeCloudkitSpec() {
  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }
}
