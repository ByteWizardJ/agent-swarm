# <Project> — Cross-Layer Interface Document

> Update each section after that layer is complete. Downstream developers must read before starting.

## 1. Contract Layer (fill after contract development)

### Deployed Addresses
| Contract | Testnet | Mainnet |
|----------|---------|---------|
| | | |

### Key Function Signatures
<!-- For each function: caller permissions, parameters, return values -->

### Events (backend pullers need to listen)
<!-- Event signature + trigger conditions + indexed fields -->

### Call Chains (frontend must pay attention)
<!-- Approve targets, cross-contract call relationships, who is msg.sender -->

### Constraints
<!-- e.g.: only supports native collateral, requires role authorization first -->

---

## 2. Backend Layer (fill after backend development)

### New/Changed APIs
<!-- Endpoint + request params + full response JSON example (annotate nested paths) -->

### New Pullers/Crons
<!-- Puller name + event listened + target table -->

### Database Changes
<!-- New table DDL / ALTER TABLE SQL -->

### Environment Variables
<!-- New env vars and format description -->

---

## 3. Frontend Layer (fill after frontend development)

### On-Chain Calls
<!-- Read: contract + function; Write: call chain + approve target + gas -->

### API Calls
<!-- Endpoint + params + response value paths -->

### On-Chain Address Sources
<!-- All addresses from dynamic config, never hardcode -->
