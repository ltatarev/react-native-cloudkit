import { Text, View } from 'react-native';
import { isAvailable } from '@ltatarev/react-native-cloudkit';

export default function App() {
  return (
    <View>
      <Text>isAvailable: {String(isAvailable())}</Text>
    </View>
  );
}
