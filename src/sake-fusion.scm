;;; Copyright (c) 2012 by Álvaro Castro Castilla
;;; Extensions for Sake, to use with Fusion projects

;;------------------------------------------------------------------------------
;;!! Setup and initialization

(define android-directory
  (make-parameter "android/"))

(define android-jni-directory-suffix
  (make-parameter "jni/"))

(define android-build-directory-suffix
  (make-parameter "build/"))

(define android-jni-directory
  (make-parameter
   (string-append (android-directory) (android-jni-directory-suffix))))

(define android-build-directory
  (make-parameter
   (string-append (android-directory) (android-jni-directory-suffix) (android-build-directory-suffix))))

(define android-src-directory-suffix
  (make-parameter "src/"))

(define android-src-directory
  (make-parameter
   (string-append (android-directory) (android-src-directory-suffix))))

(define android-link-file
  (make-parameter "linkfile_.c"))


;;------------------------------------------------------------------------------
;;!! Host programs

(define host-ant-path
  (make-parameter
   (if (zero? (shell-command "ant -version >/dev/null"))
       "ant"
       #f)))

;;------------------------------------------------------------------------------
;;!! Android SDK

;;!! Android SDK path
(define android-sdk-path
  (make-parameter
   (with-exception-catcher
    (lambda (e)
      (if (unbound-os-environment-variable-exception? e)
          #f
          (error "internal error in android-sdk-path")))
    (lambda () (getenv "ANDROID_SDK_PATH")))))

;;! Program: android
(define android-android-path
  (make-parameter
   (let ((path (string-append (android-sdk-path)
                              "/tools/android")))
     (if (file-exists? path) path #f))))

;;! Program: adb
(define android-adb-path
  (make-parameter
   (let ((path (string-append (android-sdk-path)
                              "/platform-tools/adb")))
     (if (file-exists? path) path #f))))

;;------------------------------------------------------------------------------
;; Android NDK

;;! Android NDK path
(define android-ndk-path
  (make-parameter
   (with-exception-catcher
    (lambda (e)
      (if (unbound-os-environment-variable-exception? e)
          #f
          (error "internal error in android-ndk-path")))
    (lambda () (getenv "ANDROID_NDK_PATH")))))

;;! Program: ndk-build
(define android-ndk-build-path
  (make-parameter
   (let ((path (string-append (android-ndk-path)
                              "/ndk-build")))
     (if (file-exists? path) path #f))))

;;------------------------------------------------------------------------------
;;!! Android tasks

;;! Check if Android seems to be installed in the system
(define (fusion#android-installed?)
  (unless (android-sdk-path)
          (err "Cannot find Android SDK path. Is ANDROID_SDK_PATH environment variable set?"))
  (unless (android-ndk-path)
          (err "Cannot find Android NDK path. Is ANDROID_NDK_PATH environment variable set?"))
  (unless (android-android-path)
          (err "Cannot find \"android\" program in " (android-sdk-path)  " -- Is ANDROID_SDK_PATH set to the right directory?"))
  (unless (android-adb-path)
          (err "Cannot find \"adb\" program in " (android-sdk-path)  " -- Is ANDROID_SDK_PATH set to the right directory?"))
  (unless (android-ndk-build-path)
          (err "Cannot find \"ndk-build\" program in " (android-ndk-path)  " -- Is ANDROID_NDK_PATH set to the right directory?"))
  (unless (host-ant-path)
          (err "Cannot find \"ant\" program. Is it installed?")))

;;! Check whether the project seems to be prepared for Android
(define (fusion#android-project-supported?)
  (unless (file-exists? (android-directory))
          (err "Android directory doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (android-jni-directory))
          (err "Android JNI doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (string-append (android-directory) "/build.xml"))
          (err "Android build.xml file doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (string-append (android-directory) "/AndroidManifest.xml"))
          (err "AndroidManifest.xml file doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (string-append (android-directory) "/default.properties"))
          (err "Android default.properties file doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (string-append (android-directory) "/project.properties"))
          (err "Android project.properties file doesn't exist. Is the project setup for Android compilation?"))
  (unless (file-exists? (string-append (android-directory) "/local.properties"))
          (err "Android local.properties file doesn't exist. Run (fusion#android-project-set-target <target>) in a task.")))

;;! Check update project
(define (fusion#android-project-set-target target)
  (shell-command
   (string-append (android-android-path) " update project --path " (android-directory) " --target " target)))

;;! Calls Sake android task injecting modules and
;; .parameter main-module main-module of the Android App
;; .parameter import-modules modules already generated to be linked as well
(define (fusion#android-compile-app app-name
                                    main-module
                                    #!key
                                    (cond-expand-features '())
                                    (compiler-options '())
                                    (compiled-modules '())
                                    (jni-files '("jni_bridge.c"))
                                    (target 'debug)
                                    (verbose #f))
  ;; Defines
  (define-cond-expand-feature mobile)
  (define-cond-expand-feature android)
  ;; Checks
  (fusion#android-installed?)
  (fusion#android-project-supported?)
  ;; Create the necessary directories if they don't exist
  (unless (file-exists? (android-src-directory) )
          (create-directory (android-src-directory)))
  ;; Generate Java src from templates
  (unless (file-exists? (android-build-directory))
          (create-directory (android-build-directory))
          (fusion#process-directory-with-templates (android-src-directory)
                                                   (string-append (android-directory) "src-generator/")
                                                   '(app-name) '("main")))
  ;; Compute dependencies
  (let* ((modules-to-compile (append (%module-deep-dependencies-to-load main-module) (list main-module)))
         (all-modules (append compiled-modules modules-to-compile)))
    ;; Generate modules (generates C code)
    (info/color 'blue "generating C files")
    (for-each (lambda (m) (sake#compile-to-c m
                                        cond-expand-features: (append cond-expand-features '(android mobile))
                                        compiler-options: compiler-options
                                        verbose: verbose))
              modules-to-compile)
    ;; Copy generated C from both compiled and imported modules into android build directory
    (for-each
     (lambda (m) (copy-file
             (string-append (current-build-directory)
                            (%module-filename-c m))
             (string-append (android-build-directory)
                            (%module-filename-c m))))
     all-modules)
    (fusion#android-generate-link-file all-modules)
    ;; Compile files generated by compiling modules, C files from the JNI, and the linkfile
    (let ((all-c-files
           (append (map (lambda (m) (string-append (android-build-directory-suffix) (%module-filename-c m))) all-modules)
                   (list (string-append (android-build-directory-suffix) (android-link-file)))
                   jni-files)))
      (fusion#android-generate-Android.mk-file
       (string-append (android-directory) (android-jni-directory-suffix) "Android.mk.sct")
       app-name
       all-c-files))
    ;; Call "ndk-build"
    (unless (zero? (shell-command (string-append (android-ndk-build-path) " -C " (android-directory))))
            (err "error building native code"))
    ;; Call "ant"
    (unless (zero? (shell-command (string-append (host-ant-path) " -s " (android-directory) "build.xml "
                                                 (cond ((eq? 'debug target) "debug")
                                                       ((eq? 'release target) "release")
                                                       (else (err "Unknown target parameter: fusion#android-compile-app"))))))
            (err "error building Java code"))))

;;! Generate Gambit link file
(define (fusion#android-generate-link-file modules #!key (verbose #f))
  (info/color 'blue "generating link file")
  (let* ((output-file (string-append (android-build-directory) (android-link-file)))
         (code
          `(                      ;(##include "~~spheres/prelude.scm")
            (link-incremental ',(map (lambda (m) (string-append (android-build-directory)
                                                           (%module-filename-c m)))
                                     modules)
                              output: ,output-file))))
    (if verbose (pp code))
    (unless (= 0 (gambit-eval-here code))
            (err "error generating link file"))))

;;! Generate Android.mk file from template
(define (fusion#android-generate-Android.mk-file template-file app-name c-files)
  (if (string=? ".sct" (path-extension template-file))
      (call-with-output-file
          (path-strip-extension template-file)
        (lambda (f) (display
                ((build-template-from-file template-file
                                           'main-module-name
                                           'c-files-string
                                           'c-flags-string
                                           'ld-libs-string)
                 app-name
                 (apply string-append (map (lambda (file) (string-append file " ")) c-files))
                 ""
                 "")
                f)))
      (err "template file doesn't have .sct extension")))

;;! Process a directory containing templates
(define (fusion#process-directory-with-templates project-path source-path parameters values)
  (let recur ((relative-path ""))
    (for-each
     (lambda (file)
       (case (file-info-type (file-info (string-append source-path relative-path file)))
         ((regular)
          (let ((original-file (string-append source-path relative-path file))
                (new-file (string-append project-path relative-path file)))
            (when (file-exists? new-file)
                  (println
                   "Error creating project: generators for chosen targets collide. Please contact generator author.")
                  (exit error:operation-not-permitted))
            ;; Test whether it's a generator file to process
            (if (string=? ".sct" (path-extension original-file))
                (call-with-output-file
                    (path-strip-extension new-file)
                  (lambda (f) (display
                          (apply
                           (apply
                            build-template-from-file
                            (cons (string-append source-path relative-path file)
                                  parameters))
                           values)
                          f)))
                (copy-file original-file new-file))))
         ((directory)
          (create-directory (string-append project-path relative-path file))
          (recur (string-append relative-path file "/")))))
     (directory-files (string-append source-path relative-path)))))

;;! Clean up all generated files
(define (fusion#android-clean)
  (define (delete-if-exists dir)
    (when (file-exists? dir)
          (sake#delete-directory dir recursive: #t force: #t)))
  (delete-if-exists (string-append (android-directory) "bin/"))
  (delete-if-exists (string-append (android-directory) "gen/"))
  (delete-if-exists (string-append (android-directory) "libs/"))
  (delete-if-exists (string-append (android-directory) "obj/"))
  (delete-if-exists (string-append (android-directory) "src/"))
  (delete-if-exists (android-build-directory)))

;;! Install App in Android device
(define (fusion#android-install version)
  (let ((version-str (case version ((debug) "d") ((release) "r") (else (err "Wrong version argument: fusion#android-install")))))
    (unless (zero? (shell-command (string-append (host-ant-path) " -s " (android-directory)
                                                 "build.xml install" version-str)))
            (err "App couldn't be installed in Android device."))))

;;! Run App in Android device
(define (fusion#android-run activity)
  (unless (zero? (shell-command (string-append (android-adb-path) " shell am start -n " activity)))
          (err "App couldn't be run in Android device.")))

;; ;;; Check whether fusion is precompiled
;; (define (fusion:precompiled?)
;;   (file-exists? (string-append (%sphere-path 'fusion)
;;                                (android-directory-suffix)
;;                                (android-jni-directory-suffix)
;;                                (android-build-directory-suffix))))

;; ;;; Clean all fusion files for current project
;; (define (fusion:clean)
;;   (delete-file (fusion-setup-directory) recursive: #t)
;;   (delete-file (default-lib-directory) recursive: #t))

;; ;;; Update fusion-generated C files
;; (define (fusion:update)
;;   (unless (fusion:precompiled?)
;;           (fusion:clean)
;;           (err "Prior to creating a Fusion project, you need to run 'sake compile' in Fusion Framework"))
;;   (copy-files (list (string-append (%sphere-path 'fusion) (android-directory-suffix) "jni/build"))
;;               (android-jni-directory)))

;; ;;; Check whether fusion is ready and setup for project usage
;; (define (fusion#ready?)
;;   (file-exists? (fusion-setup-directory)))

;; ;;; Setup fusion files for current project
;; (define (fusion#setup #!key (force #f))
;;   (when (or force
;;             (not (fusion#ready?)))
;;         (let* ((fusion-path (%sphere-path 'fusion))
;;                (opath (string-append fusion-path (android-directory-suffix))))
;;           (fusion#clean)
;;           (unless (fusion#precompiled?)
;;                   (fusion#clean)
;;                   (err "Prior to creating a Fusion project, you need to run 'sake compile' in Fusion Framework"))
;;           (make-directory (fusion-setup-directory))
;;           (make-directory (default-lib-directory))
;;           (make-directory (android-jni-directory))
;;           (copy-files (map (lambda (n) (string-append opath n))
;;                            '("build.xml"
;;                              "local.properties"
;;                              "proguard-project.txt"
;;                              "src"))
;;                       (android-directory))
;;           (copy-files (map (lambda (n) (string-append opath n))
;;                            '("jni/Android.mk"
;;                              "jni/Application.mk"
;;                              "jni/SDL"
;;                              "jni/build"
;;                              "jni/gambit"))
;;                       (android-jni-directory)))))


;; ;;------------------------------------------------------------------------------
;; ;;!! Android

;; ;;; Generate default Manifest and properties file
;; (define (fusion#android-generate-manifest-and-properties #!key
;;                                                          (api-level 10)
;;                                                          (app-name "Fusion App"))
;;   (info/color 'blue "generating manifest and properties files")
;;   (call-with-output-file
;;       (android-manifest-file)
;;     (lambda (file)
;;       (display
;;        (string-append
;;         "<?xml version=\"1.0\" encoding=\"utf-8\"?>
;; <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"
;;           package=\"org.libsdl.app\"
;;           android:versionCode=\"1\"
;;           android:versionName=\"1.0\"
;;           android:installLocation=\"preferExternal\">
;;   <!-- android:debuggable=\"true\" -->
;;   <uses-sdk android:minSdkVersion=\"" (number->string api-level) "\" />
;;   <uses-permission android:name=\"android.permission.WRITE_EXTERNALSTORAGE\" />
;;   <uses-permission android:name=\"android.permission.WAKE_LOCK\" />
;;   <uses-permission android:name=\"android.permission.INTERNET\" />

;;   <application android:label=\"" app-name "\">
;;     <activity android:name=\"SDLActivity\"
;;               android:label=\"" app-name "\"
;;               android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\"
;;               android:configChanges=\"orientation|keyboardHidden\">
;;       <meta-data android:name=\"android.app.lib_name\"
;;                  android:value=\"native-activity\" />
;;       <intent-filter>
;;         <action android:name=\"android.intent.action.MAIN\" />
;;         <category android:name=\"android.intent.category.LAUNCHER\" />
;;       </intent-filter>
;;     </activity>
;;   </application>
;; </manifest> 
;; "
;;         )
;;        file)))
;;   (call-with-output-file
;;       (android-project-properties-file)
;;     (lambda (file)
;;       (display
;;        (string-append "target=android-" (number->string api-level) "\n")
;;        file))))

;; ;;! Global describing necessary info for importing addons
;; (define *fusion#addons-info*
;;   '((cairo ((directories: ("cairo/" "cairo-extra/"))
;;             (dependencies: (pixman))
;;             (c-flags: "")
;;             (ld-flags: "")
;;             (android-c-includes: "cairo/src cairo-extra")
;;             (android-static-libraries: "libcairo")
;;             (android-shared-libraries: "cairo cairo-extra")))
;;     (freetype ((directories: ("freetype/"))
;;                (dependencies: ())
;;                (c-flags: "")
;;                (ld-flags: "")
;;                (android-static-libraries: "libfreetype")))
;;     (gl ((directories: (""))
;;          (dependencies: ())
;;          (c-flags: "")
;;          (ld-flags: "-lGLESv1_CM")))
;;     (libpng ((directories: ("libpng/"))
;;              (dependencies: ())
;;              (c-flags: "")
;;              (ld-flags: "")
;;              (android-static-libraries: "libpng")))
;;     (pixman ((directories: ("pixman/" "pixman-extra/"))
;;              (dependencies: ())
;;              (c-flags: "")
;;              (ld-flags: "")
;;              (android-c-includes: "pixman pixman-extra")
;;              (android-static-libraries: "libpixman cpufeatures")
;;              (android-shared-libraries: "pixman pixman-extra")))))

;; ;;! Build the system with this addon
;; (define (fusion#android-import-addon libs #!key (fresh-copy #f))
;;   (let ((fusion-path (%sphere-path 'fusion)))
;;     (for-each
;;      (lambda (lib)
;;        (let ((lib-info (assq lib *fusion#addons-info*)))
;;          (assure lib-info (err "internal error in fusion#android-import-addon"))
;;          ;; Check whether it has been imported
;;          (let ((lib-id (car lib-info)))
;;            (unless (memq lib-id *fusion#imported-addons*)
;;                    (set! *fusion#imported-addons*
;;                          (cons lib-id *fusion#imported-addons*))
;;                    (let ((lib-info-list (cadr lib-info)))
;;                      (for-each (lambda (dep) (fusion#android-import-addon (list dep)))
;;                                (uif (assq dependencies: lib-info-list)
;;                                     (cadr ?it)
;;                                     '()))
;;                      (for-each (lambda (dir)
;;                                  (let ((destination-path (string-append (android-jni-directory) dir)))
;;                                    (when (or fresh-copy
;;                                              (not (file-exists? destination-path)))
;;                                          (make-directory destination-path)
;;                                          (copy-files (fileset dir: (string-append fusion-path
;;                                                                                   (fusion-addons-directory)
;;                                                                                   dir)
;;                                                               recursive: #f)
;;                                                      destination-path))))
;;                                (cadr (assq directories: lib-info-list))))))))
;;      libs)))

;; ;;! Global holding the list of imported addons
;; (define *fusion#imported-addons* '())

;; ;;; Copies passed files to Android build directory
;; (define (fusion#android-install-modules-c-files modules)
;;   (for-each
;;    (lambda (m) (copy-file
;;            (string-append (%module-path-lib m) (%module-filename-c m))
;;            (string-append (android-build-directory)
;;                           (%module-filename-c m))))
;;    modules))

;; ;;; Calls Sake android task injecting modules and
;; ;;; compile-modules: modules to compile and link
;; ;;; compiler-options: options for Gambit compiler
;; ;;; import-modules: modules already generated to be linked as well
;; (define (fusion#android-compile-and-link compile-modules
;;                                          #!key
;;                                          (compiler-options '())
;;                                          (import-modules '()))
;;   (define-cond-expand-feature mobile)
;;   (define-cond-expand-feature android)
;;   (unless (file-exists? (fusion-setup-directory))
;;           (err "You need to use (fusion-setup) before compiling the project"))
;;   (let* ((core-modules (if (memq 'debug compiler-options)
;;                            (%module-deep-dependencies-to-load '(fusion# driver version: (debug)))
;;                            (%module-deep-dependencies-to-load '(fusion# driver))))
;;          (all-modules (%merge-module-lists
;;                        (%merge-module-lists core-modules import-modules)
;;                        ;; FIX: ideally this should fold with %module-deep-dependencies, instead of applying append
;;                        ;; but any duplicate is cleaned up in next call to %module-deep-dependencies,
;;                        ;; and order shouldn't be a problem
;;                        (apply append (map %module-deep-dependencies-to-load compile-modules)))))
    
;;     (%module-deep-dependencies-to-load '(fusion# driver version: (debug)))
;;     ;; Generate modules (generates C code)
;;     (fusion#android-generate-modules compile-modules
;;                                      compiler-options: compiler-options)
;;     ;; Copy generated C from both compiled and imported modules into android build directory
;;     (for-each
;;      (lambda (m) (copy-file
;;              (string-append (%module-path-lib m)
;;                             (%module-filename-c m))
;;              (string-append (android-build-directory)
;;                             (%module-filename-c m))))
;;      all-modules)
;;     (fusion#android-generate-link-file all-modules)
;;     ;; Generate Android.mk
;;     (fusion#android-generate-mk all-modules)
;;     ;; If Manifest or properties files are missing, write default ones
;;     (unless (and (file-exists? (android-manifest-file))
;;                  (file-exists? (android-project-properties-file)))
;;             (fusion#android-generate-manifest-and-properties))
;;     ;; Call Android build system
;;     (shell-command (string-append "ant -s " (android-directory)  "build.xml clean debug install"))))

;; ;;; Run the Android app in the device
;; (define (fusion#android-run-app)
;;   (shell-command "adb shell am start -n org.libsdl.app/.SDLActivity"))

;; ;;; Call Android clean ant task
;; (define (fusion#android-clean)
;;   (unless (= 0 (shell-command "ant -s android/build.xml clean"))
;;           (err "err in \"ant clean\" command")))

;; ;;; Upload file to SD card
;; (define (fusion#android-upload-file-to-sd relative-path)
;;   (err "unimplemented"))


;;------------------------------------------------------------------------------
;;!! Host platform

(define (fusion#host-platform)
  (let ((uname (shell-command "uname -o")))
    (cond ((equal? "GNU/Linux" uname) 'linux)
          ((equal? "Darwin" uname) 'osx)
          (else (err "fusion#host-platform -> can't detect current platform")))))

(define (fusion#host-run-interpreted main-module #!key (version '()))
  (gambit-eval-here `( ;;(##namespace (,(string-append (symbol->string (gensym 'sakefile)) "#")))
                      ;;(##include "~~lib/gambit#.scm")
                      ;;(##include "~~spheres/core/src/sake/sakelib#.scm")
                      ;;(##namespace ("" alexpand))
                      ;;(##include "~~spheres/spheres#.scm")
                      (##import ,main-module))))

(define (fusion#host-compile-exe exe-name main-module #!key
                                 (version '())
                                 (cond-expand-features '())
                                 (verbose #f))
  (sake#compile-to-exe exe-name (list main-module)
                       version: version
                       cond-expand-features: cond-expand-features
                       verbose: verbose))
