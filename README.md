# TWAMMHook - Time-Weighted Average Market Maker Hook for Uniswap v4

## Overview

TWAMMHook is a Uniswap v4 Hook designed to facilitate automated, time-weighted token buybacks for DAOs. It allows DAOs to initiate and manage buyback orders that execute gradually over a specified period, helping to reduce market impact and provide more predictable buying pressure.

## Key Features

- Initiate time-weighted buyback orders
- Update existing buyback orders
- Automatic execution of partial buybacks during swaps
- Claim bought tokens by the initiator
- View detailed buyback order information and progress

## How It Works

1. A DAO initiates a buyback order, specifying the total amount and duration.
2. The hook calculates and executes partial buybacks during regular swap operations in the pool.
3. Buybacks are spread out over the specified duration to achieve a time-weighted average price.
4. The initiator can claim the bought tokens once the buyback is complete or partially complete.

## Technical Specifications

1. Contract Structure:
   - Inherits from BaseHook and Ownable
   - Implements the beforeSwap hook

2. Key Components:
   - BuybackOrder struct: Stores details of each buyback order
   - Mappings: Track buyback orders, amounts, and claim token supply
   - State variables: DAO token address, treasury address, max buyback duration

3. Core Functionality:
   - initiateBuyback: Starts a new buyback order
   - updateBuybackOrder: Modifies an existing buyback order
   - beforeSwap: Executes partial buybacks during swaps
   - claimBoughtTokens: Allows initiators to claim purchased tokens

4. Time-Weighted Execution:
   - Calculates buyback amounts based on elapsed time
   - Executes partial buybacks during swap operations

5. Access Control:
   - Ownable functions for treasury and duration updates
   - Initiator-specific functions for order management and token claiming

6. View Functions:
   - getBuybackOrderDetails: Retrieves comprehensive order information
   - getTimeUntilNextExecution: Calculates time until next buyback execution
   - getBuybackProgress: Provides completion percentage of buyback order

7. Error Handling:
   - Custom error messages for various failure scenarios

8. Events:
   - BuybackInitiated and BuybackOrderUpdated for logging key actions

This Hook provides a flexible and gas-efficient mechanism for DAOs to perform automated, time-weighted token buybacks within the Uniswap v4 ecosystem.

## Usage

[Include basic usage instructions or link to more detailed documentation]

## Development and Testing

[Include information on how to set up the development environment, run tests, etc.]

## License

This project is licensed under the MIT License.
