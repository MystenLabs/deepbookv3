import { DeepBookClient } from "../client"
import dotenv from 'dotenv';

dotenv.config();

export const placeLimitOrder = async () => {
    const pk = process.env.PRIVATE_KEY as string;
    const balanceManagerAddress = process.env.BALANCE_MANAGER_ADDRESS as string;

    const dbClient = new DeepBookClient("testnet", pk, balanceManagerAddress);
    
}

placeLimitOrder()