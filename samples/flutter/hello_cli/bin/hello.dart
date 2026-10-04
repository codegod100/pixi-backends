import 'package:args/args.dart';

void main(List<String> arguments) {
  final parser = ArgParser()..addOption('name', defaultsTo: 'pixi');
  final results = parser.parse(arguments);
  print('Hello, ${results['name']}! (compiled with dart compile exe)');
}
