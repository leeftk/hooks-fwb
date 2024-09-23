import { useState, useEffect, useCallback } from 'react';
import { useWalletClient } from 'wagmi';
import { BrowserProvider, Contract } from 'ethers';

export function useContract(address:string, abi:any) {
  const { data: walletClient } = useWalletClient();
  const [contract, setContract] = useState<any>(null);
  const [signer, setSigner] = useState<any>(null);

  const setupContract = useCallback(async () => {
    if (walletClient && address && abi) {
      try {
        const provider = new BrowserProvider(walletClient);
        const newSigner = await provider.getSigner();
        setSigner(newSigner);
        const newContract = new Contract(address, abi, newSigner);
        setContract(newContract);
      } catch (error) {
        console.error("Error setting up contract:", error);
      }
    }
  }, [walletClient, address, abi]);

  useEffect(() => {
    setupContract();
  }, [setupContract]);

  return {
    contract,
    signer,
   
  };
}