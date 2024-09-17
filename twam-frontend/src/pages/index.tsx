import { ConnectButton } from '@rainbow-me/rainbowkit';
import type { NextPage } from 'next';
import Head from 'next/head';
import { useState, useEffect } from 'react';
import { WagmiProvider, http, useAccount } from 'wagmi'
import styles from '../styles/Home.module.css';
import { ethers } from 'ethers';
import TWAMMHookABI from '../TWAMMHook.sol/TWAMMHook.json';
import TwammLogo from '../twamm-logo.svg';
import { useWriteContract } from 'wagmi';

const poolKeyArray = [
  '0xCfF560487550C16e86f8e350A11ca0938e50a7B6', // currency0
  '0x602FB093A818C7D42c6a88848421709AEAf9587a', // currency1
  3000, // fee
  60, // tickSpacing
  "0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080" // hooks
];

interface Order {
  amountBought: bigint;
  endTime: bigint;
  interval: bigint;
  totalAmount: bigint;
  status: 'completed' | 'in progress';
  timeLeft?: bigint;
}

const Home: NextPage = () => {
  const { isConnected } = useAccount();
  const { writeContract, isLoading, isSuccess, error } = useWriteContract()

  const handleUpdateMessage = () => {
    if (isConnected) {
      writeContract({
        address: '0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080',
        abi: TWAMMHookABI.abi,
        functionName: 'updateMessage'
      });
    } else {
      console.log('Wallet not connected');
    }
  };

  const [duration, setDuration] = useState('');
  const [interval, setInterval] = useState('');
  const [quantity, setQuantity] = useState('');
  const [contract, setContract] = useState<ethers.Contract | null>(null);
  const [buybackDetails, setBuybackDetails] = useState<any>(null);
  const [daoTreasury, setDaoTreasury] = useState<string | null>(null);
  const [currentOrder, setCurrentOrder] = useState<Order | null>(null);
  const [completedOrders, setCompletedOrders] = useState<Order[]>([]);
  const [message, setMessage] = useState<string>('');

  const { address } = useAccount();

  useEffect(() => {
    const initializeContract = async () => {
      if (typeof window.ethereum !== 'undefined') {
        try {
          const provider = new ethers.BrowserProvider(window.ethereum);
          await provider.send("eth_requestAccounts", []);
          const signer = await provider.getSigner();
          const contractAddress = '0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080';
          const twammHook = new ethers.Contract(contractAddress, TWAMMHookABI.abi, signer);
          console.log("Contract initialized:", twammHook);
          setContract(twammHook);
        } catch (error) {
          console.error("Failed to initialize contract:", error);
        }
      }
    };

    initializeContract();
  }, []);

  const getBuybackDetails = async () => {
    if (contract) {
      try {
        const details = await contract.getBuybackOrderDetails(poolKeyArray);
        setBuybackDetails(details);
      } catch (error) {
        console.error("Error fetching buyback details:", error);
      }
    }
  };

  const getDaoTreasury = async () => {
    if (contract) {
      try {
        const treasury = await contract.daoTreasury();
        if (treasury === '0x' || !treasury) {
          console.warn("DAO Treasury address is empty or invalid");
          setDaoTreasury("No DAO Treasury address set");
        } else {
          setDaoTreasury(treasury);
          console.log("DAO Treasury address:", treasury);
        }
      } catch (error) {
        console.error("Error fetching DAO Treasury:", error);
        if (error.reason) console.error("Error reason:", error.reason);
        if (error.code) console.error("Error code:", error.code);
        if (error.method) console.error("Failed method:", error.method);
        setDaoTreasury("Error: Unable to fetch DAO Treasury");
      }
    } else {
      console.error("Contract not initialized");
      setDaoTreasury("Error: Contract not initialized");
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!contract) {
      console.error('Contract not initialized');
      return;
    }

    try {
      const totalAmount = ethers.parseUnits(quantity, 18);
      const durationInSeconds = BigInt(Math.floor(parseFloat(duration) * 3600)); // Convert hours to seconds
      const intervalInSeconds = BigInt(Math.floor(parseFloat(interval) * 60)); // Convert minutes to seconds
      const zeroForOne = true;

      if (durationInSeconds % intervalInSeconds !== BigInt(0)) {
        throw new Error("Duration must be divisible by interval");
      }
      console.log("log contract", contract)
      const tx = await contract.updateMessage();

      await tx.wait();
      console.log('Transaction confirmed');
      
      // Add the new order to the table as in progress
      const newOrder: Order = {
        amountBought: BigInt(0),
        endTime: BigInt(Math.floor(Date.now() / 1000) + Number(durationInSeconds)),
        interval: intervalInSeconds,
        totalAmount: totalAmount,
        status: 'in progress'
      };
      setCurrentOrder(newOrder);
      
      // Clear the form fields
      setDuration('');
      setInterval('');
      setQuantity('');
    } catch (error) {
      console.error('Error initiating buyback:', error);
      if (error.reason) console.error('Error reason:', error.reason);
      if (error.code) console.error('Error code:', error.code);
      if (error.argument) console.error('Error argument:', error.argument);
      if (error.value) console.error('Error value:', error.value);
      if (error.transaction) console.error('Error transaction:', error.transaction);
    }
  };

  const updateMessage = async () => {
    if (!contract) {
      console.error('Contract not initialized');
      return;
    }

    try {
      console.log("Updating message with contract:", contract);
      
      // Significantly increased gas limit
      const gasLimit = 1000000; // 1 million gas units

      const tx = await contract.updateMessage({ gasLimit });
      await tx.wait();
      console.log('Message update transaction confirmed');
      setMessage('Message updated successfully!');
    } catch (error) {
      console.error('Error updating message:', error);
      if (error.reason) console.error('Error reason:', error.reason);
      if (error.code) console.error('Error code:', error.code);
      if (error.method) console.error('Failed method:', error.method);
      if (error.transaction) console.error('Transaction details:', error.transaction);
      setMessage('Error updating message. Check console for details.');
    }
  };

  return (
    <div className={styles.container}>
      <Head>
        <title>TWAMM App</title>
        <meta content="TWAMM - Time-Weighted Average Market Maker" name="description" />
        <link href="/favicon.ico" rel="icon" />
      </Head>

      <nav className={styles.navbar}>
        <div className={styles.logoContainer}>
          <TwammLogo width={260} height={85} />
        </div>
        <ConnectButton />
      </nav>

      <main className={styles.main}>
        <h1 className={styles.title}>Create TWAMM Order</h1>
        <form className={styles.form} onSubmit={handleSubmit}>
          <div className={styles.inputGroup}>
            <label htmlFor="duration">Duration (in hours):</label>
            <input
              type="number"
              id="duration"
              value={duration}
              onChange={(e) => setDuration(e.target.value)}
              required
            />
          </div>
          <div className={styles.inputGroup}>
            <label htmlFor="interval">Interval (in minutes):</label>
            <input
              type="number"
              id="interval"
              value={interval}
              onChange={(e) => setInterval(e.target.value)}
              required
            />
          </div>
          <div className={styles.inputGroup}>
            <label htmlFor="quantity">Quantity to sell:</label>
            <input
              type="number"
              id="quantity"
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              required
            />
          </div>
          <button type="submit" className={styles.submitButton}>Create Order</button>
        </form>

        {isConnected && (
          <>
            <div className={styles.ordersSection}>
              <h2>Your Orders</h2>
              <table className={styles.ordersTable}>
                <thead>
                  <tr>
                    <th>Type</th>
                    <th>Duration (hours)</th>
                    <th>Interval (minutes)</th>
                    <th>Total Amount</th>
                    <th>Amount Bought</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {currentOrder && (
                    <tr>
                      <td>Current</td>
                      <td>{Math.floor(Number(currentOrder.interval) / 3600)}</td>
                      <td>{Math.floor(Number(currentOrder.interval) / 60)}</td>
                      <td>{ethers.formatEther(currentOrder.totalAmount)}</td>
                      <td>{ethers.formatEther(currentOrder.amountBought)}</td>
                      <td>{currentOrder.status}</td>
                    </tr>
                  )}
                  {completedOrders.map((order, index) => (
                    <tr key={index}>
                      <td>Completed</td>
                      <td>{ethers.formatEther(order.totalAmount)}</td>
                      <td>{ethers.formatEther(order.amountBought)}</td>
                      <td>{order.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className={styles.twammHookSection}>
              <h2>TWAMM Hook Interaction</h2>
              <div className={styles.buttonGroup}>
                <button onClick={getBuybackDetails} className={styles.actionButton}>Get Buyback Details</button>
                <button onClick={getDaoTreasury} className={styles.actionButton}>Get DAO Treasury</button>
              </div>
              <div className={styles.resultSection}>
                {buybackDetails && (
                  <div className={styles.resultBox}>
                    <h3>Buyback Details</h3>
                    <ul>
                      <li>Total Amount: {ethers.formatEther(buybackDetails.totalAmount)} ETH</li>
                      <li>Amount Bought: {ethers.formatEther(buybackDetails.amountBought)} ETH</li>
                      <li>End Time: {new Date(Number(buybackDetails.endTime) * 1000).toLocaleString()}</li>
                      <li>Execution Interval: {Number(buybackDetails.executionInterval) / 60} minutes</li>
                      <li>Last Execution Time: {new Date(Number(buybackDetails.lastExecutionTime) * 1000).toLocaleString()}</li>
                    </ul>
                  </div>
                )}
                {daoTreasury && (
                  <div className={styles.resultBox}>
                    <h3>DAO Treasury Address</h3>
                    <p>{daoTreasury}</p>
                  </div>
                )}
              </div>
            </div>

            <div className={styles.messageSection}>
              <h2>Update Message</h2>
              <button onClick={handleUpdateMessage} disabled={!isConnected || isLoading} className={styles.actionButton}>
                {isLoading ? 'Updating...' : 'Update Message'}
              </button>
              {isSuccess && <p>Message updated successfully!</p>}
              {error && <p>Error updating message</p>}
              {!isConnected && <p>Please connect your wallet</p>}
            </div>
          </>
        )}
      </main>
    </div>
  );
};

export default Home;
