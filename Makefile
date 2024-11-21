DUNE_BUILD = dune build
BIN_DIR = bin
FRONTEND_EXEC = _build/default/lib/frontend.exe
SERVER_EXEC = _build/default/lib/server.exe
FRONTEND = lib/frontend.ml
SERVER = lib/server.ml
LOG_FILE = raft.log

all: $(BIN_DIR)/frontend

# Target to build with Dune
$(FRONTEND_EXEC): $(FRONTEND)
	$(DUNE_BUILD)

# Target to build with Dune
$(SERVER_EXEC): $(SERVER)
	$(DUNE_BUILD)

# Copy executable to bin
$(BIN_DIR)/server: $(SERVER_EXEC) | $(BIN_DIR)
	rm -f $(BIN_DIR)/server
	cp $(SERVER_EXEC) $(BIN_DIR)/server

# Copy executable to bin
$(BIN_DIR)/frontend: $(FRONTEND_EXEC) | $(BIN_DIR)
	rm -f $(BIN_DIR)/frontend
	cp $(FRONTEND_EXEC) $(BIN_DIR)/frontend

# Ensure bin directory exists
$(BIN_DIR):
	mkdir -p $(BIN_DIR)

# Run frontend in the background, prepend 'frontend:' to each line, and redirect output to a log file
up: $(BIN_DIR)/frontend $(BIN_DIR)/server
	rm -f strace_*
	rm -f $(LOG_FILE)
	strace -o strace_frontend $(BIN_DIR)/frontend 2>&1 | awk '{print "frontend: " $$0; fflush()}' >> $(LOG_FILE) &

# Rule to kill the frontend and server processes
down:
	@echo "Killing frontend process..."
	@ps aux | grep 'bin/frontend' | grep -v 'grep' | awk '{print $$2}' | xargs -r kill
	@echo "Killing server processes..."
	@ps aux | grep './bin/server' | grep -v 'grep' | awk '{print $$2}' | xargs -r kill


clean:
	rm -rf $(BIN_DIR)/*
	rm -f $(LOG_FILE)
	dune clean
