;;; Copyright (c) 2012 by Álvaro Castro Castilla
;;; Test for 2d and texturing with OpenGL

(##import-include core: base-macros)
(##import-include core: assert-macros)
(##import sdl2: sdl2 version: (debug))
(##import cairo: cairo version: (debug))
(##import opengl: gl version: (debug))

(define (fusion:error . msgs)
  (SDL_LogError SDL_LOG_CATEGORY_APPLICATION
                (apply string-append
                       (map (lambda (m) (string-append
                                    (if (string? m) m (object->string m))
                                    " "))
                            msgs)))
  ;; FIX: this doesn't work for Android
  (exit 1))

(define (fusion:error-log . msgs)
  (SDL_LogError SDL_LOG_CATEGORY_APPLICATION
                (apply string-append
                       (map (lambda (m) (string-append
                                    (if (string? m) m (object->string m))
                                    " "))
                            msgs))))

(define vertex-shader #<<end-of-shader

#version 330
layout(location = 0) in vec2 position;
layout(location = 5) in vec2 texCoord;

out vec2 colorCoord;

void main()
{
  gl_Position = vec4(position, 0.0, 1.0);
  colorCoord = texCoord;
}

end-of-shader
)

(define fragment-shader #<<end-of-shader
   
#version 330

in vec2 colorCoord;
uniform sampler2D colorTexture;
out vec4 outputColor;

void main()
{
  outputColor = texture(colorTexture, colorCoord);
}

end-of-shader
)

(define (fusion:create-shader shader-type shader-code)
  (let ((shader-id (glCreateShader shader-type))
        (shader-status* (make-GLint* 1)))
    (glShaderSource shader-id 1 (list shader-code) #f)
    (glCompileShader shader-id)
    (glGetShaderiv shader-id GL_COMPILE_STATUS shader-status*)
    (if (= GL_FALSE (*->GLint shader-status*))
        (let ((info-log-length* (make-GLint* 1)))
          (glGetShaderiv shader-id GL_INFO_LOG_LENGTH info-log-length*)
          (let* ((info-log-length (*->GLint info-log-length*))
                 (info-log* (make-GLchar* info-log-length)))
            (glGetShaderInfoLog shader-id info-log-length #f info-log*)
            (error (string-append "GL Shading Language compilation -- " (char*->string info-log*))))
          ;;(free info-log-length*)
          ;;(free info-log*)
          ))
    ;;(free shader-status*)
    shader-id))

(define (fusion:create-program shaders)
  (let ((program-id (glCreateProgram))
        (program-status* (make-GLint* 1)))
   (for-each (lambda (s) (glAttachShader program-id s)) shaders)
   (glLinkProgram program-id)
   (glGetProgramiv program-id GL_LINK_STATUS program-status*)
   (if (= GL_FALSE (*->GLint program-status*))
       (let ((info-log-length* (make-GLint* 1)))
         (glGetShaderiv shader-id GL_INFO_LOG_LENGTH info-log-length*)
         (let* ((info-log-length (*->GLint info-log-length*))
                (info-log* (make-GLchar* info-log-length)))
           (glGetShaderInfoLog shader-id info-log-length #f info-log*)
           (error (string-append "GL Shading Language linkage -- " (char*->string info-log*))))
         ;;(free info-log-length*)
         ;;(free info-log*)
         ))
   (for-each (lambda (s) (glDetachShader program-id s)) shaders)
   program-id))

(define main
  (lambda (config)
    ;; If default feeds are given, then you need two: initial-events-feed and default-events-return
    (let ((init-screen-width (cadr (memq 'width: config)))
          (init-screen-height (cadr (memq 'height: config)))
          (screen-width* (make-int* 1))
          (screen-height* (make-int* 1)))
      (when (< (SDL_Init SDL_INIT_VIDEO) 0) report: (fusion:error "Couldn't initialize SDL!"))
      ;; SDL
      (let ((win (SDL_CreateWindow
                  ""
                  SDL_WINDOWPOS_CENTERED
                  SDL_WINDOWPOS_CENTERED
                  (cond-expand (mobile 0) (else init-screen-width))
                  (cond-expand (mobile 0) (else init-screen-height))
                  SDL_WINDOW_OPENGL)))
        (unless win (fusion:error "Unable to create render window" (SDL_GetError)))
        (SDL_GetWindowSize win screen-width* screen-height*)
        (let ((screen-width (*->int screen-width*))
              (screen-height (*->int screen-height*))
              (ctx (SDL_GL_CreateContext win)))
          (SDL_Log (string-append "SDL screen size: " (object->string screen-width) " x " (object->string screen-height)))
          ;; OpenGL
          (SDL_Log (string-append "OpenGL Version: " (unsigned-char*->string (glGetString GL_VERSION))))
          ;; Glew: initialize extensions
          (glewInit)
          ;; OpenGL viewport
          (glViewport 0 0 screen-width screen-height)
          (glScissor 0 0 screen-width screen-height)

          ;; Generate programs, buffers, textures
          (let* ((position-buffer-object-id* (make-GLuint* 1))
                 (main-vao-id* (make-GLuint* 1))
                 (surface-id* (make-GLuint* 1))
                 (texture-id* (make-GLuint* 1))
                 (texture-unit 0)
                 (sampler-id* (make-GLuint* 1))
                 (vertex-data-vector '#(0.75 0.75 0.0 0.0
                                             0.75 -0.75 0.0 1.0
                                             -0.75 -0.75 1.0 1.0))
                 (vertex-data (vector->GLfloat* vertex-data-vector))
                 (shaders (list (fusion:create-shader GL_VERTEX_SHADER vertex-shader)
                                (fusion:create-shader GL_FRAGMENT_SHADER fragment-shader)))
                 (shader-program (fusion:create-program shaders))
                 (texture-image* (SDL_LoadBMP "test/128x128.bmp"))
                 (texture-image (pointer->SDL_Surface texture-image*)))
            ;; Clean up shaders once the program has been compiled and linked
            (for-each glDeleteShader shaders)

            ;; Texture
            (glGenTextures 1 texture-id*)
            (glBindTexture GL_TEXTURE_2D (*->GLuint texture-id*))
            (glTexImage2D GL_TEXTURE_2D 0 3
                          (SDL_Surface-w texture-image) (SDL_Surface-h texture-image)
                          0 GL_BGR GL_UNSIGNED_BYTE
                          (SDL_Surface-pixels texture-image))
            (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_BASE_LEVEL 0)
            (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAX_LEVEL 0)
            (glBindTexture GL_TEXTURE_2D 0)
            (SDL_FreeSurface texture-image*)

            (glUseProgram shader-program)
            (glUniform1i (glGetUniformLocation shader-program "colorTexture") texture-unit)
            (glUseProgram 0)
            
            (glGenSamplers 1 sampler-id*)
            (glSamplerParameteri (*->GLuint sampler-id*) GL_TEXTURE_WRAP_S GL_CLAMP_TO_EDGE)
            (glSamplerParameteri (*->GLuint sampler-id*) GL_TEXTURE_WRAP_T GL_CLAMP_TO_EDGE)
            (glSamplerParameteri (*->GLuint sampler-id*) GL_TEXTURE_MAG_FILTER GL_NEAREST)
            (glSamplerParameteri (*->GLuint sampler-id*) GL_TEXTURE_MIN_FILTER GL_NEAREST)
	            
            ;; Vertex Array Object
            (glGenBuffers 1 position-buffer-object-id*)
            (glBindBuffer GL_ARRAY_BUFFER (*->GLuint position-buffer-object-id*))
            (glBufferData GL_ARRAY_BUFFER
                          (* (vector-length vertex-data-vector) sizeof-GLfloat)
                          (*->void* vertex-data)
                          GL_STATIC_DRAW)
            
            (glGenVertexArrays 1 main-vao-id*)
            (glBindVertexArray (*->GLuint main-vao-id*))
            (glBindBuffer GL_ARRAY_BUFFER (*->GLuint position-buffer-object-id*))
            (glEnableVertexAttribArray 0)
            (glVertexAttribPointer 0 2 GL_FLOAT GL_FALSE (* 4 sizeof-GLfloat) #f)
            (glEnableVertexAttribArray 5)
            (glVertexAttribPointer 5 2 GL_FLOAT GL_FALSE (* 4 sizeof-GLfloat) (integer->void* (* 2 sizeof-GLfloat)))
            
            (glBindVertexArray 0)
            (glBindBuffer GL_ARRAY_BUFFER 0)

            ;; Game loop
            (let* ((event (make-SDL_Event))
                   (event* (SDL_Event-pointer event)))
              (call/cc
               (lambda (quit)
                 (let main-loop ()
                   (let event-loop ()
                     (when (= 1 (SDL_PollEvent event*))
                           (let ((event-type (SDL_Event-type event)))
                             (cond
                              ((= event-type SDL_KEYDOWN)
                               (SDL_LogVerbose SDL_LOG_CATEGORY_APPLICATION "Key down")
                               (let* ((kevt (SDL_Event-key event))
                                      (key (SDL_Keysym-sym
                                            (SDL_KeyboardEvent-keysym kevt))))
                                 (cond ((= key SDLK_ESCAPE)
                                        (quit))
                                       (else
                                        (SDL_LogVerbose SDL_LOG_CATEGORY_APPLICATION (string-append "Key: " (number->string key)))))))
                              (else #f)))
                           (event-loop)))
                   (glClearColor 1.0 0.2 0.0 0.0)
                   (glClear GL_COLOR_BUFFER_BIT)

                   (glActiveTexture (+ GL_TEXTURE0 texture-unit))
                   (glBindTexture GL_TEXTURE_2D (*->GLuint texture-id*))
                   (glBindSampler texture-unit (*->GLuint sampler-id*))

                   (glBindVertexArray (*->GLuint main-vao-id*))
                   (glUseProgram shader-program)
                   (glDrawArrays GL_TRIANGLES 0 3)
                   
                   (glBindVertexArray 0)
                   (glUseProgram 0)
                   
                   (SDL_GL_SwapWindow win)
                   (main-loop))))
                                        ;(free (*->void* event*))
              (SDL_LogInfo SDL_LOG_CATEGORY_APPLICATION "Bye.")
              (SDL_GL_DeleteContext ctx)
              (SDL_DestroyWindow win)
              (SDL_Quit))))))
    (##gc)))

(main '(width: 1280 height: 752))
