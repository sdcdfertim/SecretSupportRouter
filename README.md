# Secret Support Router · Zama FHEVM

Private ticket routing for support queues using Fully Homomorphic Encryption (FHE) on Zama’s FHEVM. Users submit *encrypted* ticket profiles; agents publish *encrypted* skill vectors. The contract computes an encrypted best match (arg‑max) entirely onchain, while keeping the decision private. Only the requester and a designated RouterApp can decrypt the matched agent ID.

> **Network:** Sepolia
> **Contract:** `0xB9335126C6d39B7A694f4D896eac30Ae7d3073aE`
> **Relayer SDK:** `@zama-fhe/relayer-sdk` **0.2.0** (browser ESM from CDN in this project)
> **Solidity FHE lib:** `@fhevm/solidity` (official Zama library)

---

## Table of Contents

* [What it does](#what-it-does)
* [Main features](#main-features)
* [Architecture](#architecture)
* [Smart contract](#smart-contract)
* [Frontend](#frontend)
* [Getting started](#getting-started)
* [Project layout](#project-layout)
* [Configuration](#configuration)
* [Development tips](#development-tips)
* [Troubleshooting](#troubleshooting)
* [Security notes](#security-notes)
* [License](#license)

---

## What it does

* **Encrypted inputs:** Users submit a 4‑dimensional needs vector `need[4]` and an urgency value. Agents register their skill vectors `skill[4]`. All numbers are `uint16` and encrypted client‑side via Relayer SDK.
* **Private matching:** The contract computes a score per agent and selects the **best agent** using homomorphic operations. Matching logic:
  `score = Σ_k min(need[k], skill[k]); score += min(score, urgency)` → `best = argmax(score)`.
* **Secret result:** The best agent ID is stored onchain **encrypted** (`euint32`). Only the requester and the RouterApp address get decrypt permissions.

## Main features

* 🔐 **End‑to‑end privacy**: neither user attributes nor agent skills nor the chosen match are revealed onchain.
* 🧮 **FHE‑native scoring**: comparisons + selection via `FHE.min`, `FHE.add`, `FHE.gt`, `FHE.select`.
* 🧾 **Auditability via handles**: events expose only ciphertext handles (`bytes32`), safe to index.
* 🧰 **No-args deployment**: contract constructor takes no params; `routerApp` defaults to deployer and is changeable with `setRouterApp`.
* 🧑‍💼 **Admin agent registry**: owner can (a) upsert encrypted skills, (b) deactivate agent.

---

## Architecture

```
Browser (Relayer SDK 0.2.0)  --->  FHEVM contract (Zama)
    [encrypt need[4], urgency]      [fromExternal(); compute; select]
    [proof + handles]  ---------->  [store encrypted bestId]
    <---------- userDecrypt (EIP-712)  (best agent id → plaintext in the browser)
```

**Key idea:** all sensitive data remains encrypted onchain. Decryption happens only client‑side with user consent via EIP‑712 signature.

---

## Smart contract

* Source: `contracts/SecretSupportRouter.sol`
* Inherits `SepoliaConfig` from Zama.
* Uses only official Zama FHE lib: `import { FHE, ebool, euint16, euint32, externalEuint16 } from "@fhevm/solidity/lib/FHE.sol";`

### Public API (high level)

* `upsertAgentEncrypted(uint32 agentId, externalEuint16[4] skillExt, bytes proof, bool active)`
  Owner registers/updates an agent’s 4‑dim encrypted skills. `proof` must match the batched encrypted inputs used for `skillExt`.
* `removeAgent(uint32 agentId)`
  Deactivate the agent. (Encrypted values remain, but are ignored.)
* `submitTicketAndRoute(bytes32 ticketId, externalEuint16[4] needExt, externalEuint16 urgencyExt, bytes proof) returns (euint32)`
  User submits encrypted `need[4]` and `urgency`. Contract stores encrypted best agent ID and emits `TicketSubmitted(ticketId, user, agentIdHandle)`.
* `getMatchHandle(bytes32 ticketId) view returns (bytes32)`
  Read back the encrypted handle for a previously computed match.
* `makeMatchPublic(bytes32 ticketId)` (dev/demo)
  Mark a stored match decryptable publicly (not used by default frontend).
* `routerApp()`, `setRouterApp(address)`, `owner()`.

### ABI mapping tip

* In the ABI **for the frontend**, these FHE types map to:

  * `externalEuint16` → `bytes32`
  * `externalEuint16[4]` → `bytes32[4]`
  * Returned `euint32` is *not* read directly; we use the event handle and `userDecrypt`.

---

## Frontend

* Single‑file app at **`frontend/public/index.html`** (pure static; no build step needed).
* Technologies: Ethers v6 (ESM), Zama Relayer SDK 0.2.0 (ESM), plain HTML/CSS/JS.
* UX: two panels → **Admin · Agents** and **Submit Ticket**. New neon/neomorphic style (distinct from previous projects).
* Deep console logging with `console.groupCollapsed`: encryption, proof size, staticCall simulation, tx lifecycle, event parsing, EIP‑712 message, and userDecrypt output keys.

### User flow

1. **Connect**: wallet + network switch to Sepolia → init Relayer instance.
2. **Admin**: owner enters `agentId`, `skill[4]`, toggles active, clicks *Upsert Encrypted* → onchain encrypted storage.
3. **User**: enters `need[4]`, `urgency`, optional salt (or auto) → *Submit & Decrypt*.
4. App waits for `TicketSubmitted`, takes `agentIdHandle`, signs EIP‑712, calls `userDecrypt`, and displays the best agent ID.
5. **Lookup**: given the same salt (ticketId), you can decrypt later via *Lookup by Ticket ID*.

---

## Getting started

### Prerequisites

* Node 18+ (for local static server if you want one)
* A wallet with Sepolia test ETH (MetaMask)
* RPC endpoint for Sepolia (only needed if you serve through a dev server that proxies RPC)

### Quick run (pure static)

You can open the file directly in a modern browser, but because Relayer SDK uses WebAssembly workers, it’s safer to serve it over HTTP with correct headers.

```bash
# from project root
npx http-server frontend/public -p 5173 --cors
# then open http://localhost:5173
```

> The HTML already includes:
> `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` meta tags needed for the SDK.

### Contract deployment

Contract is already deployed to Sepolia:

```
0xB9335126C6d39B7A694f4D896eac30Ae7d3073aE
```

If you redeploy, just update the constant in `frontend/public/index.html`:

```js
const CONTRACT_ADDRESS = "0x...";
```

---

## Project layout

```
.
├─ contracts/
│  └─ SecretSupportRouter.sol
├─ deploy/
│  └─ universal-deploy.ts
├─ frontend/
│  └─ public/
│     └─ index.html      ← the UI
├─ hardhat.config.ts
└─ README.md             ← this file
```

---

## Configuration

The frontend uses CDN ESM bundles; no npm install is required. If you prefer local packages:

```bash
npm i --save ethers @zama-fhe/relayer-sdk
```

Then replace CDN imports with:

```html
<script type="module">
  import { BrowserProvider, Contract } from "ethers";
  import { initSDK, createInstance, SepoliaConfig, generateKeypair } from "@zama-fhe/relayer-sdk";
</script>
```

### Relayer endpoint

Default: `https://relayer.testnet.zama.cloud`. To change, edit `RELAYER_URL` at the top of `index.html`.

### RouterApp permissions

The contract grants decrypt rights to the caller (`msg.sender`) and to `routerApp`. After deploy, owner can rotate the RouterApp:

```solidity
function setRouterApp(address newRouter) external onlyOwner;
```

---

## Development tips

* **Batch your encrypted inputs**: all inputs for a single contract call must be produced by the *same* `createEncryptedInput()` call to share one `proof`.
* **Type ranges**: `uint16` only (0..65535). Validate in the UI before encrypting.
* **Event‑driven UX**: parse `TicketSubmitted` to get `agentIdHandle`; don’t try to parse return values of `euint*`.
* **Case sensitivity**: when reading `userDecrypt` output, match the returned keys case‑insensitively to your `handle` string.
* **Static simulation**: `contract.someMethod.staticCall(...)` is useful, but some RPCs may still revert/skip — treat it as a best‑effort.

---

---

## License

MIT — see `LICENSE` (or add your preferred license).

---

### Acknowledgements

* Zama Protocol · FHEVM Solidity L
