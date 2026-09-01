# Local libsignal JNI output

`scripts/build-libsignal-jni.sh` places locally built `libsignal_jni.so` files in
this directory for Android development and CI. The binaries are generated from
the pinned libsignal checkout, are intentionally ignored by Git, and must not be
committed or treated as release evidence.

Android release workflows rebuild the native libraries for the required ABIs
and verify the signed app bundle. Delete this directory whenever disk space is
needed; the build script recreates it.
