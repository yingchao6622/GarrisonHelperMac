"""Convert StrongholdAssistant's sprite classifier (ONNX) to a Core ML model for the Neural Engine.

Usage: python scripts/convert-sprite-model.py ../卫戍协议小助手-参考项目/StrongholdAssistant/data/sprite-model.onnx Resources/model/SpriteModel.mlpackage
Needs: pip install onnx onnx2torch torch coremltools
The ONNX graph expects RGB in [0,1] (it normalises internally), shape 1×3×192×160.
"""
import sys
import numpy as np
import onnx, torch, coremltools as ct
from onnx2torch import convert

src, dst = sys.argv[1], sys.argv[2]
model = convert(onnx.load(src)).eval()
example = torch.rand(1, 3, 192, 160)
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="logits")],
    compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "Garrison Protocol field sprite classifier (from StrongholdAssistant, Apache-2.0)"
mlmodel.save(dst)

# Numerical check against the original graph (through torch) on random images.
from PIL import Image
worst = 0
for _ in range(5):
    arr = (np.random.rand(192, 160, 3) * 255).astype(np.uint8)
    t = torch.from_numpy(arr).permute(2, 0, 1).float().unsqueeze(0) / 255
    ref = model(t).detach().numpy()[0]
    out = mlmodel.predict({"image": Image.fromarray(arr)})["logits"].reshape(-1)
    worst = max(worst, float(np.abs(ref - out).max()))
    assert ref.argmax() == out.argmax() or abs(ref.max() - ref[out.argmax()]) < 0.05
print("saved", dst, "max |Δlogit| =", round(worst, 4))
