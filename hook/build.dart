import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Every shader the renderer uses, editor and debug ones included, is in
    // the one `core` bundle (an editor package's own assets are not bundled
    // into an app).
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'core.shaderbundle.json',
      // GLSL ES 3.00 on OpenGL ES (Windows through ANGLE, Linux through
      // EGL, WebGL2 later): skinning reads joint palettes with texelFetch.
      glesLanguageVersion: 300,
    );
  });
}
