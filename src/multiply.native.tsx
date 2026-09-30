import { NitroModules } from 'react-native-nitro-modules';
import type { ReactNativeCloudkit } from './ReactNativeCloudkit.nitro';

const ReactNativeCloudkitHybridObject =
  NitroModules.createHybridObject<ReactNativeCloudkit>('ReactNativeCloudkit');

export function multiply(a: number, b: number): number {
  return ReactNativeCloudkitHybridObject.multiply(a, b);
}
