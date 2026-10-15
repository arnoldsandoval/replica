/** Starts the server on an available port bound to 127.0.0.1. */
export function listenOnLoopback(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => resolve(server.address().port))
  })
}
