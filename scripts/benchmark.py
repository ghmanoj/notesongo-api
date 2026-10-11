"""Validate and measure the help route using persistent connections (stdlib only)."""
import argparse
import concurrent.futures
import http.client
import json
import time
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8081")
    parser.add_argument("--requests", type=int, default=10000)
    parser.add_argument("--concurrency", type=int, default=32)
    args = parser.parse_args()
    if args.requests < 1 or args.concurrency < 1:
        parser.error("requests and concurrency must be positive")
    url = urlsplit(args.url)
    if url.scheme != "http" or not url.hostname:
        parser.error("url must be an http address")

    def worker(count):
        connection = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=10)
        latencies = []
        try:
            for _ in range(count):
                start = time.perf_counter()
                connection.request("POST", "/utilities_local",
                                   '{"command":"help","modifier":"command"}',
                                   {"Content-Type": "application/json"})
                response = connection.getresponse()
                reply = json.loads(response.read())
                if response.status != 200 or reply.get("type") != "help" or reply.get("status") is not True:
                    raise RuntimeError(f"Unexpected response: {response.status} {reply}")
                latencies.append((time.perf_counter() - start) * 1000)
        finally:
            connection.close()
        return latencies

    workers = min(args.requests, args.concurrency)
    counts = [args.requests // workers + (i < args.requests % workers) for i in range(workers)]
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        samples = sorted(value for batch in pool.map(worker, counts) for value in batch)
    elapsed = time.perf_counter() - start
    def percentile(fraction):
        return samples[min(len(samples) - 1, int(len(samples) * fraction))]
    print(f"{len(samples)} validated requests in {elapsed:.3f}s; {len(samples) / elapsed:.0f} requests/s")
    print(f"Latency ms: p50={percentile(.50):.3f} p95={percentile(.95):.3f} p99={percentile(.99):.3f}")


if __name__ == "__main__":
    main()
