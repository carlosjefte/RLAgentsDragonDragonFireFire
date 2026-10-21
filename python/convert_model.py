import onnx

# Caminho do seu modelo atual
onnx_path = "logs\\sb3\\onnx_exports\\model_platform_200.onnx"
output_path = "logs\\sb3\\onnx_exports\\model_platform_200_compat.onnx"

model = onnx.load(onnx_path)

# Força a IR Version para 9 (compatível com a Godot)
model.ir_version = 9 

onnx.save(model, output_path)
print(f"Modelo convertido com sucesso para IR v9: {output_path}")