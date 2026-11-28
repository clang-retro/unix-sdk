# Running programs in Haiku

`tools/haiku-vm.py` starts Haiku in QEMU and runs shell commands in it
from the host. Use it to test programs in CI without a person.

## Get an image

Use an anyboot image of Haiku, for example a nightly image from
<https://download.haiku-os.org/nightly-images/>. Use the `x86_64` image
for x86_64 programs, and the `x86_gcc2h` image for 32-bit programs.

## Commands

| Command | What it does |
|---|---|
| `haiku-vm.py serve IMAGE [--files DIR] [--shots DIR] [--port N] [--memory MB]` | starts Haiku and waits for commands |
| `haiku-vm.py exec [--port N] COMMAND` | runs COMMAND in Haiku, writes its output and exits with its status |
| `haiku-vm.py shot [--port N] NAME` | writes a screenshot to `NAME.png` in the shots directory |
| `haiku-vm.py stop [--port N]` | stops QEMU |
| `haiku-vm.py run IMAGE SCRIPT [--files DIR] [--shots DIR]` | starts Haiku, runs the shell script SCRIPT, stops QEMU and exits with the status of the script |

The default port is 8765.

## How it works

1. The tool starts QEMU with a copy of the image. QEMU uses KVM when
   `/dev/kvm` is available. Without KVM, the start takes some minutes.
2. The tool reads the serial output of Haiku. When the first-boot dialog
   shows, the tool pushes Enter to start the desktop.
3. The tool opens Terminal with the keyboard (through the Tracker
   windows) and types one command. This command gets a small agent from
   the host and starts it.
4. The agent asks the host for jobs over HTTP. QEMU's user network gives
   the host the address `10.0.2.2`. The agent runs each job with `sh` and
   sends the output and the exit status back to the host.

In Haiku, a job can get files from the host:

    curl -sf -o prog http://10.0.2.2:8765/files/prog

The file comes from the `--files` directory. A job can also ask for a
screenshot:

    curl -s http://10.0.2.2:8765/shot/NAME

The host writes `NAME.png` into the `--shots` directory.

## Requirements

- `qemu-system-x86_64` (also for the 32-bit image) on the PATH.
- Python 3.
- QEMU 7.1 or later, which can write PNG screenshots.
