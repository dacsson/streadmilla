all: build

# Check if FILE is provided
ifeq ($(FILE),)
	$(error Please specify FILE=your_file.c)
endif

# Extract base name (without extension) for output
FILE_NAME := $(basename $(FILE))

build: dune-build link

# Step 1: Build with dune
dune-build:
	@echo "🏗️  Building with dune..."
	@dune build
	@echo "✅ Dune build completed."

# Step 2: Compile C file and link with gc.so
link:
	@echo "🔗 Compiling $(FILE) and linking with gc.so..."
	@gcc -std=c11 $(FILE) stella/runtime.c  -I . -L . -l:_build/default/stella/gc.so -o $(FILE_NAME)
	@echo "✅ Executable created: $(FILE_NAME)"

# Clean up
clean:
	@echo "🧹 Cleaning up..."
	@dune clean
	@rm -f $(FILE_NAME)
	@echo "✅ Clean complete."

# Help message
help:
	@echo "Usage: make FILE=example_stella/try_out.c"
	@echo "  Example: make FILE=example_stella/try_out.c"
	@echo "  Clean: make clean"
	@echo "  Build: make build"

# Ensure all targets are phony
.PHONY: all build dune-build link clean help
