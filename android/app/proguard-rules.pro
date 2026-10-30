# Google Mobile Ads brings in WorkManager 2.7 / Room 2.2.5. Room creates
# WorkDatabase_Impl by reflection during AndroidX Startup, before Flutter runs.
# The old Room consumer rules keep the class but R8 full mode removes its
# no-argument constructor, causing "Failed to create an instance of WorkDatabase".
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}

# WorkManager 2.7 also constructs InputMergers by reflection; its consumer rules
# likewise keep only their classes, so explicitly preserve their constructors.
-keep class * extends androidx.work.InputMerger {
    public <init>();
}
