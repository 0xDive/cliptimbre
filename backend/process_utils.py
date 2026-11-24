"""Process creation flags for the ClipTimbre backends."""

import subprocess

# Resolve starts these backends from a GUI. Console children such as FFmpeg
# must also be started without a console, even if the Python parent has none.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
