import 'package:firebase_core/firebase_core.dart';

// Fill these 4 values from your Firebase project.
// Firebase console -> Project settings (gear icon) -> Your apps -> Android app.
// They are the same values that appear inside google-services.json:
//   apiKey            = "current_key"
//   appId             = "mobilesdk_app_id"
//   messagingSenderId = "project_number"
//   projectId         = "project_id"
const String apiKey = 'AIzaSyB1lozsqXhKE_8qiKAdNzYxUd-GSPlhpN0';
const String appId = '1:144085335283:android:e9f7a5bd2ba7a6a16acb86';
const String messagingSenderId = '144085335283';
const String projectId = 'kalam-finder';

bool get firebaseConfigured => !apiKey.startsWith('PASTE') && !projectId.startsWith('PASTE');

const FirebaseOptions firebaseOptions = FirebaseOptions(
  apiKey: apiKey,
  appId: appId,
  messagingSenderId: messagingSenderId,
  projectId: projectId,
);
