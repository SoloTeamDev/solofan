CC = clang
CFLAGS = -Wall -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -framework IOKit -framework CoreFoundation
TARGET = smc-helper

all: $(TARGET)

$(TARGET): smc.c smc.h
	$(CC) $(CFLAGS) -o $(TARGET) smc.c

clean:
	rm -f $(TARGET)

install: $(TARGET)
	cp $(TARGET) ../../fan/Resources/

.PHONY: all clean install
