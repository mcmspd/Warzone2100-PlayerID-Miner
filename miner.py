import argparse
import base64
import hashlib
import multiprocessing as mp
import os
import struct
import sys
import time
from nacl.signing import SigningKey


def format_time(seconds):
    """Format seconds into a clean human-readable string (e.g., '2d 5h' or '4m 12s')."""
    if seconds < 0:
        return "0s"
    if seconds < 60:
        return f"{int(seconds)}s"
    elif seconds < 3600:
        return f"{int(seconds // 60)}m {int(seconds % 60)}s"
    elif seconds < 86400:
        return f"{int(seconds // 3600)}h {int((seconds % 3600) // 60)}m"
    else:
        days = int(seconds // 86400)
        hours = int((seconds % 86400) // 3600)
        return f"{days}d {hours}h"


def _make_seed(node_id, process_index, counter):
    """Deterministically produce a 32-byte Ed25519 seed from unique worker coordinates."""
    return hashlib.sha256(
        struct.pack(">I", node_id)      # 4 bytes: device ID
        + struct.pack(">I", process_index)  # 4 bytes: local process ID
        + struct.pack(">Q", counter)      # 8 bytes: per-process counter
    ).digest()


def miner_worker(
    prefix,
    target_found,
    result_queue,
    total_hashes,
    node_id,
    process_index,
    start_offset,
    batch_size=5000,
):
    """Worker process that mines a unique, non-overlapping partition of the key space."""
    local_attempts = 0
    counter = start_offset
    checkpoint_path = f".vanity_checkpoint_n{node_id}_p{process_index}.txt"

    while not target_found.is_set():
        seed = _make_seed(node_id, process_index, counter)
        signing_key = SigningKey(seed=seed)
        pubkey_bytes = bytes(signing_key.verify_key)

        player_id = base64.b64encode(pubkey_bytes).decode("utf-8")
        local_attempts += 1
        counter += 1

        # Periodic batch update to shared memory to avoid lock contention
        if local_attempts >= batch_size:
            with total_hashes.get_lock():
                total_hashes.value += local_attempts
            local_attempts = 0

        # Save checkpoint every ~1M hashes so resuming skips already-checked keys
        if counter % 1_000_000 == 0:
            try:
                with open(checkpoint_path, "w") as f:
                    f.write(str(counter))
            except Exception:
                pass

        if player_id.startswith(prefix):
            target_found.set()

            with total_hashes.get_lock():
                total_hashes.value += local_attempts

            keypair_bytes = bytes(signing_key) + pubkey_bytes
            secret_key = base64.b64encode(keypair_bytes).decode("utf-8")

            result_queue.put((secret_key, player_id, node_id, process_index, counter))
            return


def get_resume_offset(node_id, process_index, cli_offset):
    """Return the best offset to resume from: checkpoint file if present, else CLI offset."""
    checkpoint_path = f".vanity_checkpoint_n{node_id}_p{process_index}.txt"
    if os.path.exists(checkpoint_path):
        try:
            with open(checkpoint_path, "r") as f:
                return int(f.read().strip())
        except Exception:
            pass
    return cli_offset


def mine_player_id(prefix, num_processes=None, node_id=0, start_offset=0, resume=False):
    if num_processes is None:
        num_processes = mp.cpu_count()

    prefix_len = len(prefix)

    # Statistical baseline calculations
    expected_avg_hashes = 64**prefix_len
    expected_99_hashes = int(4.605 * expected_avg_hashes)

    print("==================================================")
    print(f"[*] Target Prefix      : '{prefix}' ({prefix_len} characters)")
    print(f"[*] Expected Avg Hashes: {expected_avg_hashes:,}")
    print(f"[*] Practical Max (99%): {expected_99_hashes:,}")
    print(f"[*] Node ID            : {node_id}")
    print(f"[*] Local Processes    : {num_processes}")
    print(f"[*] Global Worker Tag  : (node={node_id}, proc=0..{num_processes-1})")
    print("==================================================\n")

    target_found = mp.Event()
    total_hashes = mp.Value("q", 0)  # Shared 64-bit integer
    result_queue = mp.Queue()
    processes = []

    start_time = time.time()

    # Launch worker processes, each with a unique (node_id, process_index) identity
    for process_index in range(num_processes):
        offset = (
            get_resume_offset(node_id, process_index, start_offset)
            if resume
            else start_offset
        )
        p = mp.Process(
            target=miner_worker,
            args=(
                prefix,
                target_found,
                result_queue,
                total_hashes,
                node_id,
                process_index,
                offset,
            ),
        )
        p.daemon = True
        p.start()
        processes.append(p)

    # Live monitoring loop in main thread
    try:
        while not target_found.is_set():
            time.sleep(0.3)
            elapsed = time.time() - start_time
            mined = total_hashes.value
            speed = mined / elapsed if elapsed > 0 else 0

            # Estimate remaining time based on current speed
            if speed > 0:
                hashes_remaining = max(0, expected_avg_hashes - mined)
                eta_seconds = hashes_remaining / speed
                eta_str = format_time(eta_seconds)
            else:
                eta_str = "Calculating..."

            # Calculate progress percentage relative to average expected hashes
            pct_complete = (mined / expected_avg_hashes) * 100

            # Print live statistics on a single refreshing line
            sys.stdout.write(
                f"\r[*] Hashes: {mined:,} ({pct_complete:.1f}% Avg) | "
                f"Speed: {speed:,.0f} H/s | ETA: {eta_str}   "
            )
            sys.stdout.flush()

        secret_key, player_id, found_node, found_proc, found_counter = result_queue.get()

    except KeyboardInterrupt:
        print("\n\n[-] Mining interrupted by user.")
        target_found.set()
        for p in processes:
            p.terminate()
        sys.exit(0)

    for p in processes:
        p.terminate()

    elapsed = time.time() - start_time
    final_hashes = total_hashes.value
    avg_speed = final_hashes / elapsed if elapsed > 0 else 0

    print(f"\n\n[+] MATCH FOUND in {format_time(elapsed)} ({elapsed:.2f}s)!")
    print("--------------------------------------------------")
    print(f"Total Hashes Mined : {final_hashes:,}")
    print(f"Average Speed      : {avg_speed:,.0f} H/s")
    print(f"Found by Node      : {found_node}")
    print(f"Found by Process   : {found_proc}")
    print(f"Counter at Match   : {found_counter:,}")
    print(f"Secret Key (88 ch) : {secret_key}")
    print(f"Player ID  (44 ch) : {player_id}")
    print("--------------------------------------------------")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=(
            "Distributed Ed25519 Vanity Player ID Miner. "
            "Run on multiple devices with unique --node-id values for zero overlap."
        )
    )
    parser.add_argument(
        "prefix",
        type=str,
        help="Target prefix for Player ID (case-sensitive Base64 characters)",
    )
    parser.add_argument(
        "-t",
        "--threads",
        type=int,
        default=mp.cpu_count(),
        help="Number of CPU worker threads on this device (default: all cores)",
    )
    parser.add_argument(
        "-n",
        "--node-id",
        type=int,
        default=0,
        help="Unique integer ID for this device in the cluster (default: 0)",
    )
    parser.add_argument(
        "-o",
        "--offset",
        type=int,
        default=0,
        help="Starting counter offset for all local processes (default: 0)",
    )
    parser.add_argument(
        "-r",
        "--resume",
        action="store_true",
        help="Resume from per-process checkpoint files if they exist",
    )

    args = parser.parse_args()

    mine_player_id(
        prefix=args.prefix,
        num_processes=args.threads,
        node_id=args.node_id,
        start_offset=args.offset,
        resume=args.resume,
    )
