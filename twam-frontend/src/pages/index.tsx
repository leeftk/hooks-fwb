import { ConnectButton } from "@rainbow-me/rainbowkit";
import type { NextPage } from "next";
import Head from "next/head";
import { useState, useEffect } from "react";
import { WagmiProvider, http, useAccount } from "wagmi";
import styles from "../styles/Home.module.css";
import { ethers } from "ethers";
import TWAMMHookABI from "../TWAMMHook.sol/TWAMMHook.json";
import TwammLogo from "../twamm-logo.svg";
import { useWriteContract } from "wagmi";
import { CreateOrder } from "@/components/orders/create-order";
import { WalletIcon } from "lucide-react";
import { Button } from "@/components/ui/button";

const poolKeyArray = [
  "0xCfF560487550C16e86f8e350A11ca0938e50a7B6", // currency0
  "0x602FB093A818C7D42c6a88848421709AEAf9587a", // currency1
  3000, // fee
  60, // tickSpacing
  "0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080", // hooks
];

interface Order {
  amountBought: bigint;
  endTime: bigint;
  interval: bigint;
  totalAmount: bigint;
  status: "completed" | "in progress";
  timeLeft?: bigint;
}

const Home: NextPage = () => {
  const { isConnected } = useAccount();
  const { writeContract, isLoading, isSuccess, error } = useWriteContract();

  const handleUpdateMessage = () => {
    if (isConnected) {
      writeContract({
        address: "0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080",
        abi: TWAMMHookABI.abi,
        functionName: "updateMessage",
      });
    } else {
      console.log("Wallet not connected");
    }
  };

  const [duration, setDuration] = useState("");
  const [interval, setInterval] = useState("");
  const [quantity, setQuantity] = useState("");
  const [contract, setContract] = useState<ethers.Contract | null>(null);
  const [buybackDetails, setBuybackDetails] = useState<any>(null);
  const [daoTreasury, setDaoTreasury] = useState<string | null>(null);
  const [currentOrder, setCurrentOrder] = useState<Order | null>(null);
  const [completedOrders, setCompletedOrders] = useState<Order[]>([]);
  const [message, setMessage] = useState<string>("");

  const { address } = useAccount();

  useEffect(() => {
    const initializeContract = async () => {
      if (typeof window.ethereum !== "undefined") {
        try {
          const provider = new ethers.BrowserProvider(window.ethereum);
          await provider.send("eth_requestAccounts", []);
          const signer = await provider.getSigner();
          const contractAddress = "0x76118c7e1B8D4f0813688747Fb73c8ce9A4B8080";
          const twammHook = new ethers.Contract(
            contractAddress,
            TWAMMHookABI.abi,
            signer
          );
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
        if (treasury === "0x" || !treasury) {
          console.warn("DAO Treasury address is empty or invalid");
          setDaoTreasury("No DAO Treasury address set");
        } else {
          setDaoTreasury(treasury);
          console.log("DAO Treasury address:", treasury);
        }
      } catch (error: any) {
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
      console.error("Contract not initialized");
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
      console.log("log contract", contract);
      const tx = await contract.updateMessage();

      await tx.wait();
      console.log("Transaction confirmed");

      // Add the new order to the table as in progress
      const newOrder: Order = {
        amountBought: BigInt(0),
        endTime: BigInt(
          Math.floor(Date.now() / 1000) + Number(durationInSeconds)
        ),
        interval: intervalInSeconds,
        totalAmount: totalAmount,
        status: "in progress",
      };
      setCurrentOrder(newOrder);

      // Clear the form fields
      setDuration("");
      setInterval("");
      setQuantity("");
    } catch (error: any) {
      console.error("Error initiating buyback:", error);
      if (error.reason) console.error("Error reason:", error.reason);
      if (error.code) console.error("Error code:", error.code);
      if (error.argument) console.error("Error argument:", error.argument);
      if (error.value) console.error("Error value:", error.value);
      if (error.transaction)
        console.error("Error transaction:", error.transaction);
    }
  };

  const updateMessage = async () => {
    if (!contract) {
      console.error("Contract not initialized");
      return;
    }

    try {
      console.log("Updating message with contract:", contract);

      // Significantly increased gas limit
      const gasLimit = 1000000; // 1 million gas units

      const tx = await contract.updateMessage({ gasLimit });
      await tx.wait();
      console.log("Message update transaction confirmed");
      setMessage("Message updated successfully!");
    } catch (error: any) {
      console.error("Error updating message:", error);
      if (error.reason) console.error("Error reason:", error.reason);
      if (error.code) console.error("Error code:", error.code);
      if (error.method) console.error("Failed method:", error.method);
      if (error.transaction)
        console.error("Transaction details:", error.transaction);
      setMessage("Error updating message. Check console for details.");
    }
  };

  return (
    <div className={styles.container}>
      <Head>
        <title>TWAMM App</title>
        <meta
          content="TWAMM - Time-Weighted Average Market Maker"
          name="description"
        />
        <link href="/favicon.ico" rel="icon" />
      </Head>

      <nav className={styles.navbar}>
        <div className={styles.logoContainer}>
          <TwammLogo width={260} height={85} />
        </div>
        <ConnectButton />
      </nav>

      <main className={styles.main}>
        {isConnected ? (
          <div className="flex flex-col lg:flex-row gap-16">
            <div className="w-full lg:w-3/4">
              <div className="">
                <div className="flex justify-between items-center mb-8">
                  <h2 className="text-2xl font-semibold text-gray-900">
                    Your Orders
                  </h2>
                  <CreateOrder />
                </div>
                {/* <table className={styles.ordersTable}>
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
              </table> */}

                <h2 className="font-medium text-gray-700 mb-4">
                  Current Order
                </h2>

                <div className="bg-white shadow overflow-hidden sm:rounded-lg mb-12">
                  <table className="min-w-full divide-y divide-gray-200">
                    <thead className="bg-gray-50">
                      <tr>
                        {[
                          "Duration (hours)",
                          "Interval (minutes)",
                          "Total Amount",
                          "Amount Bought",
                          "Status",
                        ].map((header) => (
                          <th
                            key={header}
                            className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"
                          >
                            {header}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody className="bg-white divide-y divide-gray-200">
                      {currentOrder ? (
                        <tr>
                          <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                            {24 ||
                              Math.floor(Number(currentOrder.interval) / 3600)}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {60 ||
                              Math.floor(Number(currentOrder.interval) / 60)}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {1000 ||
                              ethers.formatEther(currentOrder.totalAmount)}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {500 ||
                              ethers.formatEther(currentOrder.amountBought)}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-gray-100 text-gray-800">
                              {"Current" || currentOrder.status}
                            </span>
                          </td>
                        </tr>
                      ) : (
                        <tr>
                          <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-500">
                            {24}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {60}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {1000}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            {500}
                          </td>
                          <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                            <span className="px-2 inline-flex text-xs leading-5 font-bold rounded-full bg-green-200 text-green-800">
                              {"Current"}
                            </span>
                          </td>
                        </tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <h2 className="font-medium text-gray-700 mb-4">
                  Completed Orders
                </h2>
                <div className="bg-white shadow overflow-hidden sm:rounded-lg">
                  <table className="min-w-full divide-y divide-gray-200">
                    <thead className="bg-gray-50">
                      <tr>
                        {["Total Amount", "Amount Bought", "Status"].map(
                          (header) => (
                            <th
                              key={header}
                              className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"
                            >
                              {header}
                            </th>
                          )
                        )}
                      </tr>
                    </thead>
                    <tbody className="bg-white divide-y divide-gray-200">
                      {/* {completedOrders?.map((order, index) =>  ( */}
                      <tr>
                        <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-500">
                          {
                            2000
                            // ||  ethers.formatEther(order.totalAmount)
                          }
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {
                            1000
                            // || ethers.formatEther(order.amountBought)
                          }
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-gray-200 text-gray-800">
                            {
                              "Completed"
                              // ||order.status
                            }
                          </span>
                        </td>
                      </tr>
                      {/* ))} */}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <div className="w-full lg:w-1/3 ">
              <h2 className="text-2xl font-medium text-gray-900 mb-4">Hook Interactions</h2>

              <div className="p-6 border border-gray-300 rounded-2xl">
                <div>
                  <div className={styles.buttonGroup}>
                    <Button
                      onClick={getBuybackDetails}
                    className="bg-blue-600 hover:bg-blue-700"
                    >
                      Get Buyback Details
                    </Button>
                    <Button
                    variant={'ghost'}
                      onClick={getDaoTreasury}
                    className="bg-transparent text-gray-800 border border-gray-800 hover:bg-gray-700 hover:text-white"
                      
                    >
                      Get DAO Treasury
                    </Button>
                  </div>
                  <div className={styles.resultSection}>
                    {buybackDetails && (
                      <div className={styles.resultBox}>
                        <h3>Buyback Details</h3>
                        <ul>
                          <li>
                            Total Amount:{" "}
                            {ethers.formatEther(buybackDetails.totalAmount)} ETH
                          </li>
                          <li>
                            Amount Bought:{" "}
                            {ethers.formatEther(buybackDetails.amountBought)}{" "}
                            ETH
                          </li>
                          <li>
                            End Time:{" "}
                            {new Date(
                              Number(buybackDetails.endTime) * 1000
                            ).toLocaleString()}
                          </li>
                          <li>
                            Execution Interval:{" "}
                            {Number(buybackDetails.executionInterval) / 60}{" "}
                            minutes
                          </li>
                          <li>
                            Last Execution Time:{" "}
                            {new Date(
                              Number(buybackDetails.lastExecutionTime) * 1000
                            ).toLocaleString()}
                          </li>
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
                  <h2 className="font-medium text-gray-700 mt-6 mb-3">Update Message</h2>
                  <button
                    onClick={handleUpdateMessage}
                    disabled={!isConnected || isLoading}
                    className={styles.actionButton}
                  >
                    {isLoading ? "Updating..." : "Update Message"}
                  </button>
                  {isSuccess && <p>Message updated successfully!</p>}
                  {error && <p>Error updating message</p>}
                  {!isConnected && <p>Please connect your wallet</p>}
                </div>
              </div>
            </div>
          </div>
        ) : (
          <div className=" flex flex-col items-center justify-center">
            <WalletIcon className="mx-auto h-12 w-12 text-gray-400 mb-4" />
            <p className="text-lg font-medium text-gray-900 mb-2">
              Wallet Not Connected
            </p>
            <p className="text-sm text-gray-600 mb-4">
              Please connect your wallet to access this feature.
            </p>
          </div>
        )}
      </main>
    </div>
  );
};

export default Home;
