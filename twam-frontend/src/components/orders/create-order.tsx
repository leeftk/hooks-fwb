"use client";

import { useState } from "react";

import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Button } from "../ui/button";
import { ethers } from "ethers";
import { Label } from "../ui/label";
import { Input } from "../ui/input";

export function CreateOrder() {


  interface Order {
    amountBought: bigint;
    endTime: bigint;
    interval: bigint;
    totalAmount: bigint;
    status: 'completed' | 'in progress';
    timeLeft?: bigint;
  }


  const [open, setOpen] = useState(false);
  const [duration, setDuration] = useState('');
  const [interval, setInterval] = useState('');
  const [quantity, setQuantity] = useState('');
  const [contract, setContract] = useState<ethers.Contract | null>(null);;
  const [currentOrder, setCurrentOrder] = useState<Order | null>(null);


  function closeModal() {
    setOpen(false);
  }

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
      closeModal()
    } catch (error:any) {
      console.error('Error initiating buyback:', error);
      if (error.reason) console.error('Error reason:', error.reason);
      if (error.code) console.error('Error code:', error.code);
      if (error.argument) console.error('Error argument:', error.argument);
      if (error.value) console.error('Error value:', error.value);
      if (error.transaction) console.error('Error transaction:', error.transaction);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          className={`mr-2 px-4 py-2 font-sans text-sm font-semibold`}
        >
          Create
        </Button>
      </DialogTrigger>

      <DialogContent>
      <DialogTitle>
      Create TWAMM Order
      </DialogTitle>
      <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="duration">Duration (in hours):</Label>
            <Input
              type="number"
              id="duration"
              value={duration}
              onChange={(e) => setDuration(e.target.value)}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="interval">Interval (in minutes):</Label>
            <Input
              type="number"
              id="interval"
              value={interval}
              onChange={(e) => setInterval(e.target.value)}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="quantity">Quantity to sell:</Label>
            <Input
              type="number"
              id="quantity"
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              required
            />
          </div>
          <Button type="submit" className="w-full">Create Order</Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
