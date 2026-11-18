# Gallery Pick on iOS: models, frameworks and their licences

What the iOS gallery scan runs on the shopper's phone, where each piece comes
from, and the licence it is used under. Everything runs on the device; no
photo, face measurement or embedding leaves the phone for any of these models.

## 1. Third-party models bundled in the app

| Model | What it does in Gallery Pick | Source and version | Licence | Modified by Swan |
|---|---|---|---|---|
| SFace face recognition (`FaceRecognitionSFace.mlpackage`, 10 MB) | The face embedding: the distance between the selfie and each library photo decides a match | OpenCV Zoo, `face_recognition_sface_2021dec` (ONNX). Model from the paper "SFace: Sigmoid-Constrained Hypersphere Loss for Robust Face Recognition" (2021). https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface | Apache License 2.0 (the model's LICENSE file in OpenCV Zoo) | Yes: converted from ONNX to a Core ML package, 8-bit weights. Behaviour unchanged |
| MediaPipe Face Landmarker (`face_landmarker.task`, 3.8 MB) | 478 face points: head yaw, pitch and roll, gaze, blink, expression blendshapes, and face alignment before SFace | Google MediaPipe Solutions, Face Landmarker. https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker | Apache License 2.0 (per the model card) | No |
| MediaPipe Selfie Multiclass segmenter (`selfie_multiclass_256x256.tflite`, 16 MB) | Person mask: body outline readings (torso and legs fit, arms, loose clothing) and face cover (hairline, jaw, face) | Google MediaPipe Solutions, Image Segmenter, "Selfie multiclass" model. https://ai.google.dev/edge/mediapipe/solutions/vision/image_segmenter | Apache License 2.0 (per the model card) | No |
| MediaPipe EfficientDet-Lite0 object detector (`efficientdet_lite0.tflite`, 4.6 MB) | Bags, umbrellas, bikes, chairs over or beside the body; people count; animals beside the shopper | Google MediaPipe Solutions, Object Detector, EfficientDet-Lite0. Trained on COCO 2017. https://ai.google.dev/edge/mediapipe/solutions/vision/object_detector | Apache License 2.0 (per the model card) | No |

## 2. Third-party framework bundled in the app

| Framework | What it does | Source and version | Licence |
|---|---|---|---|
| MediaPipe Tasks Vision for iOS (CocoaPods `MediaPipeTasksVision` and `MediaPipeTasksCommon`) | Runs the three MediaPipe models above | Google, version 0.10.21. https://github.com/google-ai-edge/mediapipe | Apache License 2.0 (LICENSE file ships in each pod) |

No OpenCV code is bundled on iOS; the SFace model runs through Apple's Core ML.

## 3. Apple frameworks (part of iOS, nothing bundled)

Used under the Apple Developer Program License Agreement and the Xcode and
Apple SDKs Agreement. No third-party licence applies and nothing is
redistributed.

| Apple API | What it does in Gallery Pick |
|---|---|
| Vision: face rectangles, face landmarks | Finding faces, face size, eye spacing |
| Vision: face capture quality | Choosing the selfie reference frame |
| Vision: human body pose | Lower joints, head-to-toe check, photo type (front, side, three-quarter) |
| Vision: human hand pose | Hand over or near the face |
| Vision: image classification | Clothing labels (suit, jacket, gown, sari, hoodie), sunglasses, cap, scarf, dressy and busy reads, document labels |
| Vision: person segmentation, human rectangles | Group and bystander checks |
| Vision: text rectangles, document segmentation | The document gate |
| Vision: image feature print | Duplicate grouping |
| Core ML | Runs the SFace model |
| SensitiveContentAnalysis | The sensitivity filter, only when Apple grants the entitlement |
| Photos (PhotoKit) | Reading the library with the shopper's permission |

## 4. Web page loaded inside the app

The Gallery Pick page (Swan's web component) runs in the app's web view and
loads one model for the live selfie guide before the capture.

| Piece | What it does | Source and version | Licence |
|---|---|---|---|
| MediaPipe Face Detection, full-range model, through TensorFlow.js (WASM backend) | Face position, size and brightness hints while the shopper lines up the selfie | `@tensorflow-models/face-detection` 1.0.x, `@mediapipe/face_detection` 0.4.x, `@tensorflow/tfjs` 4.15.x, all from Google. Model file served from Swan's CDN | Apache License 2.0 (all three packages and the model) |

## 5. What the licences ask of Swan

Every third-party piece above is Apache License 2.0. It is permissive, with no
copyleft and no fee. Its conditions, as they apply here:

- Keep the licence text. Ship a copy of the Apache 2.0 licence with the app
  (an acknowledgements screen or a bundled LICENSES file), naming each item
  in sections 1, 2 and 4.
- Keep any NOTICE file a package ships, and show its contents with the
  licence text. The MediaPipe pods carry a LICENSE only.
- State modifications. The SFace model was converted to Core ML and
  quantised; the acknowledgement for it should say so.
- No trademark use. Google, MediaPipe, TensorFlow and OpenCV names are used
  only to identify the components.
- The licence grants a patent licence from the contributors for the code and
  models as supplied.

Nothing in the app's own code is derived from these projects beyond calling
them; Swan's code stays under Swan's own terms.

## 6. Points legal may want to confirm

- Model cards: the Apache 2.0 statement for the three MediaPipe models comes
  from Google's model cards at the links in section 1. Worth a copy on file.
- Training data: EfficientDet-Lite0 was trained on COCO 2017 (annotations
  CC BY 4.0; images under their own Flickr terms). The training data of the
  other models is described in their papers and model cards. This matters
  only if training-data provenance is in scope.
- SensitiveContentAnalysis needs an entitlement from Apple before it works;
  without it the filter is off and the app behaves the same otherwise.
- Face recognition: SFace produces a face embedding, used on the device only
  to match the shopper's own selfie against their own photos. The app's scan
  store keeps the embeddings of candidate photos on the phone, in a file named
  by a hash of the account and excluded from iCloud and computer backups, so a
  second scan is fast. They are never sent anywhere, and the scan report posted
  from sandbox builds carries none.
