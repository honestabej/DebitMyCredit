import 'dotenv/config';
import crypto from "crypto";
import express from "express";
import sql from "mssql";
import cors from "cors";
import axios from "axios";
import bcrypt from "bcryptjs";
import { v4 as uuidv4 } from "uuid";

const app = express();
app.use(express.json());
app.use(cors());

// Azure SQL config
const azureConfig = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  database: process.env.DB_NAME,
  options: { encrypt: true }
};

// AES Encryption Setup
const ALGO = "aes-256-gcm";
const KEY = Buffer.from(process.env.ENCRYPTION_KEY, "hex"); // 32-byte hex

// Server steup for testing
const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server running on port ${port}`));
// wakeDatabase();

/*****************************************
 * HELPER FUNCTIONS
 *****************************************/
function encrypt(text) {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv(ALGO, KEY, iv);
  let encrypted = cipher.update(text, "utf8", "hex");
  encrypted += cipher.final("hex");
  const tag = cipher.getAuthTag().toString("hex");
  return { data: encrypted, iv: iv.toString("hex"), tag };
}

function decrypt({ data, iv, tag }) {
  const decipher = crypto.createDecipheriv(ALGO, KEY, Buffer.from(iv, "hex"));
  decipher.setAuthTag(Buffer.from(tag, "hex"));
  let decrypted = decipher.update(data, "hex", "utf8");
  decrypted += decipher.final("utf8");
  return decrypted;
}

async function hashPassword(plain) {
  const salt = await bcrypt.genSalt(10);
  return bcrypt.hash(plain, salt);
}

// Send a call to the Azure DB to wake up on server start
async function wakeDatabase() {
  try {
    console.log("Waking Azure DB...");
    const pool = await sql.connect(azureConfig);
    await pool.request().query("SELECT 1");
    console.log("Azure DB is awake.");
  } catch (err) {
    console.error("Failed to wake Azure DB:", err);
  }
}

// Wrapper function to ensure Azure DB is awake before sending any requests
async function safeQuery(work, maxRetries = 5, baseDelay = 2000) {
  let attempt = 0;

  while (attempt < maxRetries) {
    try {
      return await work();
    } catch (err) {
      attempt++;
      console.warn(`Attempt ${attempt} failed: ${err.message}`);

      if (attempt >= maxRetries) {
          throw err; // Give up after maxRetries
      }

      await wakeDatabase();

      // Exponential backoff: wait longer each retry
      const delay = baseDelay * Math.pow(2, attempt - 1);
      console.log(`Waiting ${delay}ms before retrying...`);
      await new Promise(r => setTimeout(r, delay));
    }
  }
}

// This gets the date of 30 days ago and converts it to UNIX time, to be used in the simpleFin API call
function getUnixTime30DaysAgo() {
  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  return Math.floor(thirtyDaysAgo.getTime() / 1000);
}

// This function is in charge of making the call to simpleFin and returning a JSON object containing all of the accounts connected to simpleFin
async function fetchSimpleFinAccounts(userID) {
  // Connect Azure DB
  const pool = await sql.connect(azureConfig);

  // Get the user's simpleFin credentials
  const userResult = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.VarChar(50), userID)
    .query(`
      SELECT 
      simpleFinUsernameData, simpleFinUsernameIV, simpleFinUsernameTag,
      simpleFinPasswordData, simpleFinPasswordIV, simpleFinPasswordTag
      FROM Users
      WHERE id = @userID
    `);
  });

  if (userResult.recordset.length === 0) throw new Error("User not found");

  // Decrypt the credentials before sending them to simpleFin
  const simpleFinUsername = decrypt({
      data: userResult.recordset[0].simpleFinUsernameData,
      iv: userResult.recordset[0].simpleFinUsernameIV,
      tag: userResult.recordset[0].simpleFinUsernameTag
  });

  const simpleFinPassword = decrypt({
      data: userResult.recordset[0].simpleFinPasswordData,
      iv: userResult.recordset[0].simpleFinPasswordIV,
      tag: userResult.recordset[0].simpleFinPasswordTag
  });

  // Call to the simplefin API
  const response = await axios.get(
    `https://beta-bridge.simplefin.org/simplefin/accounts`,
    { auth: { username: simpleFinUsername, password: simpleFinPassword } }
  );

  return response.data.accounts || [];
}

// This function is in charge of making the call to simpleFin and returning a JSON object containing all of the latest data and the last 30 days of transactions
async function fetchSimpleFinData(userID) {
  // Connect Azure DB
  const pool = await sql.connect(azureConfig);

  // Get the user's simpleFin credentials
  const userResult = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.VarChar(50), userID)
    .query(`
      SELECT 
      simpleFinUsernameData, simpleFinUsernameIV, simpleFinUsernameTag,
      simpleFinPasswordData, simpleFinPasswordIV, simpleFinPasswordTag
      FROM Users
      WHERE id = @userID
    `);
  });

  if (userResult.recordset.length === 0) throw new Error("User not found");

  // Decrypt the credentials before sending them to simpleFin
  const simpleFinUsername = decrypt({
      data: userResult.recordset[0].simpleFinUsernameData,
      iv: userResult.recordset[0].simpleFinUsernameIV,
      tag: userResult.recordset[0].simpleFinUsernameTag
  });

  const simpleFinPassword = decrypt({
      data: userResult.recordset[0].simpleFinPasswordData,
      iv: userResult.recordset[0].simpleFinPasswordIV,
      tag: userResult.recordset[0].simpleFinPasswordTag
  });

  // Get the Unix Timecode of the date 30 days ago
  const unixTime = getUnixTime30DaysAgo();

  // Call to the simplefin API
  const response = await axios.get(
    `https://beta-bridge.simplefin.org/simplefin/accounts?include=transactions&start-date=${unixTime}`,
    { auth: { username: simpleFinUsername, password: simpleFinPassword } }
  );

  return response.data.accounts || [];
}

// Iterates through the JSON SimpleFin object and adds any new accounts to the Azure DB
async function importNewAccounts(userID, accounts) {
  if (!accounts || !accounts.length) return 0;

  const pool = await sql.connect(azureConfig);
  let insertedCount = 0;

  for (const acc of accounts) {
    const result = await pool.request()
      .input("id", sql.VarChar(50), acc.id)
      .input("userID", sql.UniqueIdentifier, userID)
      .input("name", sql.VarChar(255), acc.name)
      .input("acctBalance", sql.Decimal(18, 2), parseFloat(acc["available-balance"]))
      .input("activeBalance", sql.Decimal(18, 2), parseFloat(acc["available-balance"]))
      .input("isDebit", sql.Bit, null)
      .query(`
        IF NOT EXISTS (SELECT 1 FROM Accounts WHERE id = @id)
        BEGIN
            INSERT INTO Accounts (id, userID, name, acctBalance, activeBalance, isDebit)
            VALUES (@id, @userID, @name, @acctBalance, @activeBalance, @isDebit);
        END
        SELECT @@ROWCOUNT AS affectedRows;
      `);

    // Only increment if a row was actually inserted
    if (result.recordset[0].affectedRows > 0) {
      insertedCount += 1;
    }
  }

  return insertedCount;
}

// Iterates through the JSON SimpleFin object and updates the balances of all debit acocounts
async function updateDebitAccountBalances(userID, accounts) {
  if (!accounts || !accounts.length) return 0;
  
  // Connect to the Azure DB
  const pool = await sql.connect(azureConfig);

  // Get debit accounts from the Azure DB
  const debitAccounts = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.VarChar(50), userID)
    .query(`SELECT id, acctBalance, updatedAt FROM DebitAccounts WHERE userID = @userID`);
  });

  // Create a map of the debit accounts and their account balances
  const debitAccountsMap = new Map();
  debitAccounts.recordset.forEach(acc => debitAccountsMap.set(acc.id, acc));

  // Keep track of how many account balances were updated
  let acctBalanceUpdateCt = 0

  // Loop through all of the simpleFin accounts
  for (const account of accounts) {
    // Skip if the DebitAccounts table does not have this simpleFin account
    if (!debitAccountsMap.has(account.id)) continue;

    const dbAccount = debitAccountsMap.get(account.id);
    const currBalance = debitAccountsMap.get(account.id);
    const simpleFinBalance = parseFloat(account["available-balance"]);
    const currUpdatedAt = new Date(dbAccount.updatedAt);
    const simpleFinUpdatedAt = new Date(account["balance-date"] * 1000);

    // Convert SimpleFin unix timestamp to Date
    const simpleFinBalanceDate = new Date(account["balance-date"] * 1000);
    
    // Update the balance of they do not match and the simpleFin date is newer
    if (simpleFinUpdatedAt > currUpdatedAt && currBalance !== simpleFinBalance) {
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.VarChar(50), account.id)
        .input("activeBalance", sql.Decimal(18, 2), simpleFinBalance) // Keeping synced for now, may change
        .input("acctBalance", sql.Decimal(18, 2), simpleFinBalance) 
        .input("balanceDate", sql.DateTimeOffset, simpleFinBalanceDate)
        .query(`
            UPDATE DebitAccounts
            SET activeBalance = @activeBalance,
                acctBalance = @acctBalance,
                balanceDate = @balanceDate,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @id
        `);
      });

      acctBalanceUpdateCt += 1;
    }
  }
  
  return acctBalanceUpdateCt;
}

// Iterates through the JSON SimpleFin object and adds any new transactions from credit card accounts to the Azure DB
async function importNewTransactions(userID, accounts) {
  if (!accounts || !accounts.length) return 0;
  
  // Connect to the Azure DB
  const pool = await sql.connect(azureConfig);

  // Get credit accounts from the Azure DB
  const creditAccounts = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.VarChar(50), userID)
    .query(`SELECT id FROM CreditAccounts WHERE userID = @userID`);
  });
  const creditAccountIds = new Set(creditAccounts.recordset.map(row => row.id));

  // Get the transactions of the last 60 days from the Azure DB
  const sixtyDaysAgoDate = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000);
  const existingTransactions = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.VarChar(50), userID)
    .input("dateLimit", sql.DateTimeOffset, sixtyDaysAgoDate)
    .query(`SELECT id FROM Transactions WHERE userID = @userID AND transactionDate >= @dateLimit`);
  });
  const existingTransactionIds = new Set(existingTransactions.recordset.map(row => row.id));

  // Keep track of how many transactions were inserted
  let insertedTransactionsCt = 0;

  // Loop through all of the simpleFin accounts
  for (const account of accounts) {
    // Skip if the CreditAccounts table does not have this simpleFin account
    if (!creditAccountIds.has(account.id)) continue;
    if (!account.transactions || !account.transactions.length) continue;

    // Loop though the transactions of the account
    for (const transaction of account.transactions) {
      // Skip if already exists
      if (existingTransactionIds.has(transaction.id)) continue;

      // Insert new transaction
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.VarChar(50), transaction.id)
        .input("userID", sql.VarChar(50), userID)
        .input("creditAccountID", sql.VarChar(50), account.id)
        .input("name", sql.NVarChar(255), transaction.description || transaction.payee || "Unknown")
        .input("amount", sql.Decimal(18, 2), parseFloat(transaction.amount))
        .input("transactionDate", sql.DateTimeOffset, new Date(transaction.posted * 1000))
        .input("notes", sql.NVarChar(sql.MAX), transaction.memo || "")
        .query(`
          INSERT INTO Transactions (id, userID, creditAccountID, name, amount, transactionDate, notes)
          VALUES (@id, @userID, @creditAccountID, @name, @amount, @transactionDate, @notes)
        `);
      });

      insertedTransactionsCt++;
    }
  }

  return insertedTransactionsCt;
}

async function syncUser(clientUser) {
  // Connect to the Azure DB
  const pool = await sql.connect(azureConfig);

  // Fetch the user from the DB
  const dbResult = await safeQuery(async () => {
    return pool.request()
    .input("id", sql.UniqueIdentifier, clientUser.userID)
    .query(`SELECT id, email, fetchFrequency, lastSimpleFinSync, updatedAt FROM Users WHERE id = @id`);
  });

  if (dbResult.recordset.length === 0) {
    return { error: "User not found" }
  }

  const serverUser = dbResult.recordset[0];
  const clientTimestamp = new Date(clientUser.updatedAt);
  const serverTimestamp = new Date(serverUser.updatedAt);

  // Determine which copy wins
  if (clientTimestamp > serverTimestamp) {
    // Update the server with client-provided fields
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.UniqueIdentifier, userID)
      .input("email", sql.VarChar(255), email)
      .input("fetchFrequency", sql.Int, fetchFrequency)
      .query(`
        UPDATE Users
        SET 
          email = @email,
          fetchFrequency = @fetchFrequency,
          updatedAt = SYSUTCDATETIME()
        WHERE id = @id
      `);
    });

    // Re-fetch after update
    const refreshed = await safeQuery(async () => {
      return pool.request()
      .input("id", sql.UniqueIdentifier, clientUser.userID)
      .query(`SELECT id, email, fetchFrequency, lastSimpleFinSync, updatedAt FROM Users WHERE id = @id`);
    });

    return { success: true, resolvedUser: refreshed.recordset[0] }
  } else {
    // Server wins, just return server data
    return { success: true, resolvedUser: serverUser }
  }
}

async function syncDebitAccounts(userID, clientAccounts) {
  // Connect to the Azure DB
  const pool = await sql.connect(azureConfig);

  // Fetch all accounts from server DB
  const dbResult = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.UniqueIdentifier, userID)
    .query(`
      SELECT id, updatedAt
      FROM DebitAccounts
      WHERE userID = @userID
    `);
  });

  const dbAccounts = dbResult.recordset;

  // Map server accounts by id for quick lookup
  const dbMap = new Map();
  dbAccounts.forEach(acc => dbMap.set(acc.id, acc));

  // Loop through client accounts and sync editable fields
  for (const clientAcc of clientAccounts) {
    // Skip any client account that has not been imported to the Azure DB (shouldn't be possible)
    const dbAcc = dbMap.get(clientAcc.id);
    if (!dbAcc) continue; 

    const clientUpdated = new Date(clientAcc.updatedAt);
    const serverUpdated = new Date(dbAcc.updatedAt);

    // If client is more recent, update those fields
    if (clientUpdated > serverUpdated) {
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.VarChar(50), clientAcc.id)
        .input("name", sql.NVarChar(255), clientAcc.name)
        .query(`
          UPDATE DebitAccounts
          SET 
            name = @name,
            updatedAt = SYSUTCDATETIME()
          WHERE id = @id
        `);
      });
    }
  }

  // Refetch server to get updated info
  const refreshed = await safeQuery(async () => {
    return pool.request()
    .input("userID", sql.UniqueIdentifier, userID)
    .query(`
      SELECT id, name, acctBalance, activeBalance, balanceDate, updatedAt
      FROM DebitAccounts
      WHERE userID = @userID
    `);
  });

  return {success: true, accounts: refreshed.recordset}
}

async function syncTransactions(userID, clientTransactions, lastSuccessfulServerSync) {
  if (!userID) throw new Error("userID required");

  // Connect to Azure DB
  const pool = await sql.connect(azureConfig);

  // Variables to keep track of inserted and updated transactions
  let updatedCount = 0;
  const updatedTransactionIDs = [];

  // First loop through the transactions sent by the client
  for (const clientTx of clientTransactions) {
    // Fetch server version of client transaction
    const serverTxResult = await safeQuery(async () => {
      return pool.request()
      .input("id", sql.VarChar(50), clientTx.id)
      .input("userID", sql.UniqueIdentifier, userID)
      .query(`
        SELECT id, updatedAt
        FROM Transactions
        WHERE id = @id AND userID = @userID
      `);
    });

    const serverTx = serverTxResult.recordset[0];
    if (!serverTx) continue; // shouldn't happen but safe guard

    const serverUpdated = new Date(serverTx.updatedAt);
    const clientUpdated = new Date(clientTx.updatedAt);

    // If client version is more recent then update server
    if (clientUpdated > serverUpdated) {
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.VarChar(50), clientTx.id)
        .input("notes", sql.NVarChar(sql.MAX), clientTx.memo || "")
        .input("transferGroupID", sql.UniqueIdentifier, clientTx.transferGroupID || null)
        .input("updatedAt", sql.DateTimeOffset, clientUpdated)
        .query(`
          UPDATE Transactions
          SET notes = @notes,
              transferGroupID = @transferGroupID,
              updatedAt = @updatedAt
          WHERE id = @id
        `);
      });

      // Now sync the transaction allocation information
      if (Array.isArray(clientTx.allocations)) {
        // Delete existing allocations for this transaction
        await safeQuery(async () => {
          return pool.request()
          .input("transactionID", sql.VarChar(50), clientTx.id)
          .query(`
            DELETE FROM TransactionAllocations
            WHERE transactionID = @transactionID
          `);
        });

        // Insert new allocations
        for (const alloc of clientTx.allocations) {
          await safeQuery(async () => {
            return pool.request()
            .input("transactionID", sql.VarChar(50), clientTx.id)
            .input("debitAccountID", sql.VarChar(50), alloc.debitAccountID)
            .input("amount", sql.Decimal(18,2), alloc.amount)
            .query(`
              INSERT INTO TransactionAllocations (transactionID, debitAccountID, amount)
              VALUES (@transactionID, @debitAccountID, @amount)
            `);
          });
        }
      }

      updatedCount++;
      updatedTransactionIDs.push(clientTx.id);
    }
  }

  // Refetch all of the transactions that we just updated
  let updatedTransactions = [];
  if (updatedTransactionIDs.length > 0) {
    const request = pool.request().input("userID", sql.UniqueIdentifier, userID);

    updatedTransactionIDs.forEach((id, index) => {
      request.input(`id${index}`, sql.VarChar(50), id);
    });

    const idParams = updatedTransactionIDs.map((_, i) => `@id${i}`).join(",");

    const updatedResult = await safeQuery(async () => {
      return request.query(`
        SELECT *
        FROM Transactions
        WHERE userID = @userID AND id IN (${idParams}) 
        ORDER BY transactionDate DESC
      `);
    });

    updatedTransactions = updatedResult.recordset;
  }

  // Fetch any new transactions that have been imported after the lastSuccesfulSync
  let newTransactions = [];

  if (lastSuccessfulServerSync) {
    const newTxResult = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.UniqueIdentifier, userID)
      .input("lastSync", sql.DateTimeOffset, lastSuccessfulServerSync)
      .query(`
        SELECT *
        FROM Transactions
        WHERE userID = @userID AND updatedAt > @lastSync
        ORDER BY transactionDate DESC
      `);
    });

    newTransactions = newTxResult.recordset;
  } else {
    // first sync → return all
    const allTxResult = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.UniqueIdentifier, userID)
      .query(`
        SELECT *
        FROM Transactions
        WHERE userID = @userID
        ORDER BY transactionDate DESC
      `);
    });

    newTransactions = allTxResult.recordset;
  }

  // Remove deuplicates
  newTransactions = newTransactions.filter(tx => !updatedTransactionIDs.includes(tx.id));

  return {
    success: true,
    updated: updatedCount,
    updatedTransactions,  
    newTransactions     
  };
}

async function syncTransferGroups(userID, clientTransferGroups, lastSuccessfulServerSync) {
  if (!userID) throw new Error("userID required");

  const pool = await sql.connect(azureConfig);

  let insertedCount = 0;
  let updatedCount = 0;

  const updatedTGIDs = [];
  const updatedGroups = [];
  let newGroups = [];

  // First loop through the transferGroups sent by the client
  for (const clientTransferGroup of clientTransferGroups) {
    const clientUpdatedAt = new Date(clientTransferGroup.updatedAt);

    // Check if TG exists on the server
    const serverTGResult = await safeQuery(async () => {
      return pool.request()
      .input("id", sql.UniqueIdentifier, clientTransferGroup.id)
      .input("userID", sql.UniqueIdentifier, userID)
      .query(`
        SELECT id, updatedAt
        FROM TransferGroups
        WHERE id = @id AND userID = @userID
      `);
    });

    const serverTG = serverTGResult.recordset[0];

    // If the transferGroup does not exist on the server, create it
    if (!serverTG) {
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.UniqueIdentifier, clientTransferGroup.id)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), clientTransferGroup.name)
        .input("notes", sql.NVarChar(sql.MAX), clientTransferGroup.notes || "")
        .input("updatedAt", sql.DateTimeOffset, clientUpdatedAt)
        .query(`
          INSERT INTO TransferGroups (id, userID, name, notes, updatedAt)
          VALUES (@id, @userID, @name, @notes, @updatedAt)
        `);
      });

      insertedCount++;
      updatedTGIDs.push(clientTransferGroup.id); 
    } else {
      const serverUpdatedAt = new Date(serverTG.updatedAt);

      if (clientUpdatedAt > serverUpdatedAt) {
        // Update server
        await safeQuery(async () => {
          return pool.request()
          .input("id", sql.UniqueIdentifier, clientTransferGroup.id)
          .input("name", sql.NVarChar(255), clientTransferGroup.name)
          .input("updatedAt", sql.DateTimeOffset, clientUpdatedAt)
          .query(`
            UPDATE TransferGroups
            SET name = @name,
                updatedAt = @updatedAt
            WHERE id = @id
          `);
        });

        updatedCount++;
        updatedTGIDs.push(clientTransferGroup.id);
      }
    }
  }

  // Refetch all of the trasferGroups that we just updated
  if (updatedTGIDs.length > 0) {
    const req = pool.request();
    updatedTGIDs.forEach((id, i) => req.input(`id${i}`, sql.UniqueIdentifier, id));

    const updatedResult = await safeQuery(async () => {
      return req.query(`
        SELECT *
        FROM TransferGroups
        WHERE id IN (${updatedTGIDs.map((_, i) => `@id${i}`).join(",")})
      `);
    });

    updatedGroups.push(...updatedResult.recordset);
  }

  // Get any new transferGroups that have been added to the server since the lastSuccessfulSync
  if (lastSuccessfulServerSync) {
    const req2 = pool.request()
      .input("userID", sql.UniqueIdentifier, userID)
      .input("lastSync", sql.DateTimeOffset, lastSuccessfulServerSync);

    // exclude updated ones
    updatedTGIDs.forEach((id, i) => req2.input(`ex${i}`, sql.UniqueIdentifier, id));

    const excludeClause = updatedTGIDs.length
      ? `AND id NOT IN (${updatedTGIDs.map((_, i) => `@ex${i}`).join(",")})`
      : "";

    const newResult = await safeQuery(async () => {
      return req2.query(`
        SELECT *
        FROM TransferGroups
        WHERE userID = @userID
          AND updatedAt > @lastSync
          ${excludeClause}
      `);
    });

    newGroups = newResult.recordset;
  }

  return {
    success: true,
    inserted: insertedCount,
    updated: updatedCount,
    updatedGroups,
    newGroups
  };
}

/*****************************************
 * API Endpoints
 *****************************************/
// Default route to verify server status
app.get("/", (req, res) => res.send("Server is running"));

// Register a new user
app.post("/register", async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    const pool = await sql.connect(azureConfig);

    // Check if email already exists
    const existing = await safeQuery(async () => {
      return pool.request()
        .input("email", sql.VarChar(255), email)
        .query(`SELECT id FROM Users WHERE email = @email`);
    });

    if (existing.recordset.length > 0) {
      return res.status(409).json({ 
        success: false, 
        error: "Email already exists" 
      });
    }

    // Hash password and generate userID
    const hashed = await hashPassword(password);
    const id = uuidv4();

    // Insert new user into the Azure DB
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.VarChar(50), id)
      .input("email", sql.VarChar(255), email)
      .input("passwordHash", sql.VarChar(255), hashed)
      .input("fetchFrequency", sql.Int, 2)
      .input("lastSimpleFinSync", sql.DateTime, null)
      .query(`
        INSERT INTO Users (
          id, email, passwordHash, fetchFrequency, lastSimpleFinSync
        )
        VALUES (@id, @email, @passwordHash, @fetchFrequency, @lastSimpleFinSync)
      `);
    });

    // Create a "Manual" transfer group by default for all users
    const tgid = uuidv4();
    await safeQuery(async () => {
      return pool.request()
      .input("tgid", sql.VarChar(50), tgid)
      .input("userID", sql.VarChar(50), id)
      .input("name", sql.VarChar(255), "Manual")
      .query(`
        INSERT INTO TransferGroups (
          id, userID, name
        )
        VALUES (@tgid, @userID, @name)
      `);
    });

    // Fetch the newly created user and transfer group to return to the client
    const newUserResult = await safeQuery(async () => {
      return pool.request()
        .input("id", sql.VarChar(50), id)
        .query(`
          SELECT 
            id,
            email,
            fetchFrequency,
            lastSimpleFinSync,
            createdAt,
            updatedAt
          FROM Users
          WHERE id = @id
        `);
    });

    const newUser = newUserResult.recordset[0];

    // const newTransferGroupResult = await safeQuery(async () => {
    //   return pool.request()
    //     .input("tgid", sql.VarChar(50), tgid)
    //     .query(`
    //       SELECT 
    //         id,
    //         userID,
    //         name,
    //         createdAt,
    //         updatedAt
    //       FROM TransferGroups
    //       WHERE id = @tgid
    //     `);
    // });

    // const newTransferGroup = newTransferGroupResult.recordset[0];

    res.json({ 
      success: true, 
      message: `New user registered`,
      user: newUser
    });

  } catch (e) {
    console.error("/register returned the following error: ", e);
    res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Login an existing user with email/password
app.post("/login", async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) return res.status(400).json({ success: false, error: "Missing fields" });
    
    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);

    // Select user with query
    const result = await safeQuery(async () => {
      return pool.request()
      .input("email", sql.VarChar(255), email)
      .query(`
        SELECT id, email, fetchFrequency, lastSimpleFinSync, simpleFinUsernameData, createdAt, updatedAt, passwordHash
        FROM Users
        WHERE email = @email
      `);
    });

    // Ensure email exists, and compare the passwords
    if (result.recordset.length === 0) return res.json({ success: false, message: "Invalid email and password" });    
    const user = result.recordset[0];
    const valid = await bcrypt.compare(password, user.passwordHash);

    // Remove simpleFinUsernameData and passwordHash before returning
    const simpleFinCredentialsSet = !!user.simpleFinUsernameData;
    delete user.simpleFinUsernameData;
    delete user.passwordHash;    

    // Return json success/fail 
    if (!valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    } else {
      return res.json({ success: true, user: { ...user, simpleFinCredentialsSet }});
    }

  } catch (e) {
    console.error("/login returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Add a user's simpleFin username and password to Azure
app.post("/connect-simplefin", async (req, res) => {
  try {
    const { userID, simpleFinUsername, simpleFinPassword } = req.body;
    if (!userID || !simpleFinUsername || !simpleFinPassword) return res.status(400).json({ error: "userID, username, and password required" });

    // Encrypt the simpleFin username and password
    const usernameEnc = encrypt(simpleFinUsername);
    const passwordEnc = encrypt(simpleFinPassword);

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);

    // Insert the encrypted credentials with thefollowing query
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.VarChar(50), userID)
      .input("usernameData", sql.VarChar(sql.MAX), usernameEnc.data)
      .input("usernameIV", sql.VarChar(32), usernameEnc.iv)
      .input("usernameTag", sql.VarChar(32), usernameEnc.tag)
      .input("passwordData", sql.VarChar(sql.MAX), passwordEnc.data)
      .input("passwordIV", sql.VarChar(32), passwordEnc.iv)
      .input("passwordTag", sql.VarChar(32), passwordEnc.tag)
      .query(`
        UPDATE Users
        SET simpleFinUsernameData=@usernameData,
          simpleFinUsernameIV=@usernameIV,
          simpleFinUsernameTag=@usernameTag,
          simpleFinPasswordData=@passwordData,
          simpleFinPasswordIV=@passwordIV,
          simpleFinPasswordTag=@passwordTag,
          updatedAt = SYSUTCDATETIME()
        WHERE id=@id
      `);
    });

    // Send request to SimpleFin with new credentials to verify theyre correct and populate the user's accounts
    const response = await axios.get(
      `https://beta-bridge.simplefin.org/simplefin/accounts`,
      { auth: { username: simpleFinUsername, password: simpleFinPassword } }
    );

    // Check if the response gave permission or not
    if (response.data.errors?.includes("Forbidden")) {
      return res.json({ success: true, message: "SimpleFIN credentials saved, but SimpleFIN returned an access error. Please ensure SimpleFIN credentials are correct."});
    }

    // Save the user's accounts to otherAccounts
    for (const account of response.data.accounts) {
      
      const balanceDate = account["balance-date"] 
        ? new Date(account["balance-date"] * 1000) 
        : null;

      // If the account not exist on any accounts table, add it to the OtherAccounts table
      await safeQuery(async () => {
        return pool.request()
        .input("id", sql.VarChar(50), account.id)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), account.name)
        .input("acctBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
        .input("activeBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0) // TODO: May deprecate in futue
        .input("balanceDate", sql.DateTimeOffset, balanceDate)
        .query(`
          IF NOT EXISTS (
              SELECT 1 FROM DebitAccounts WHERE id = @id
              UNION ALL
              SELECT 1 FROM CreditAccounts WHERE id = @id
              UNION ALL
              SELECT 1 FROM OtherAccounts WHERE id = @id
          )
          BEGIN
              INSERT INTO OtherAccounts (id, userID, name, acctBalance, activeBalance, balanceDate)
              VALUES (@id, @userID, @name, @acctBalance, @activeBalance, @balanceDate)
          END 
        `);
      });
    }    

    return res.json({ success: true, message: "SimpleFIN credentials saved and SimpleFIN accessed successfully!"});

  } catch (e) {
    console.error("/connect-simplefin returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  } 
});

// Remove a user's simplefin credentials
app.post("/remove-simplefin", async (req, res) => {
  try {
    const { userID } = req.body;
    if (!userID ) return res.status(400).json({ error: "userID required" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);

    // Insert the encrypted credentials with thefollowing query
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.VarChar(50), userID)
      .query(`
        UPDATE Users
        SET
          simpleFinUsernameData = NULL,
          simpleFinUsernameIV = NULL,
          simpleFinUsernameTag = NULL,
          simpleFinPasswordData = NULL,
          simpleFinPasswordIV = NULL,
          simpleFinPasswordTag = NULL,
          updatedAt = SYSUTCDATETIME()
        WHERE id=@id
      `);
    });   

    return res.json({ success: true, message: "SimpleFIN credentials removed"});

  } catch (e) {
    console.error("/remove-simplefin returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  } 
});

// Initiate a call to simpleFin to get all available accounts
app.get("/get-simplefin-accounts", async (req, res) => {
    try { 
    const userID = req.query.userID;
    if (!userID) return res.status(400).json({ error: "No userID provided" });

    // Get and decrypt the user's simpleFin credentials, call to simpleFin API, and return the JSON response
    const simpleFinResponse = await fetchSimpleFinAccounts(userID);

    // Return a message to the user 
    return res.json({ success: true, simpleFinResponse: simpleFinResponse});
    
  } catch(e) {
    console.error("/get-simplefin-accounts returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Insert new accounts into the Azure DB
app.post("/insert-accounts", async (req, res) => {
  try { 
    const { userID, debitAccounts, creditAccounts } = req.body;
    if (!userID) return res.status(400).json({ error: "No userID provided" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);

    let insertedDebitCount = 0;
    let insertedCreditCount = 0;

    // Insert the debitAccounts to the Azure DB
    if (debitAccounts && debitAccounts.length) {
      for (const debitAccount of debitAccounts) {
        // Use IF NOT EXISTS to prevent duplicates
        await safeQuery(async () => {
          return pool.request()
          .input("id", sql.VarChar(50), debitAccount.id)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("name", sql.NVarChar(255), debitAccount.name)
          .input("acctBalance", sql.Decimal(18, 2), parseFloat(debitAccount["available-balance"]) || 0)
          .input("activeBalance", sql.Decimal(18, 2), parseFloat(debitAccount["available-balance"]) || 0) // TODO: May deprecate in futue
          .query(`
            IF NOT EXISTS (SELECT 1 FROM DebitAccounts WHERE id = @id)
            BEGIN
              INSERT INTO DebitAccounts (id, userID, name, acctBalance, activeBalance)
              VALUES (@id, @userID, @name, @acctBalance, @activeBalance)
            END 
          `);
        });

        insertedDebitCount++;
      }
    }

    // Insert the creditAccounts to the Azure DB
    if (creditAccounts && creditAccounts.length) {
      for (const acc of creditAccounts) {
        await safeQuery(async () => {
          return pool.request()
          .input("id", sql.VarChar(50), acc.id)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("name", sql.NVarChar(255), acc.name)
          .query(`
            IF NOT EXISTS (SELECT 1 FROM CreditAccounts WHERE id = @id)
            BEGIN
              INSERT INTO CreditAccounts (id, userID, name)
              VALUES (@id, @userID, @name)
            END
          `);
        });

        insertedCreditCount++;
      }
    }

    return res.json({
      success: true,
      insertedDebitAccounts: insertedDebitCount,
      insertedCreditAccounts: insertedCreditCount
    });
    
  } catch(e) {
    console.error("/insert-accounts returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Initiate a call to simpleFin to populate Azure DB with most recent account balances and transactions (NOTE: Runs automatically every x hours to keep Azure DB up to date)
app.post("/sync-simplefin-data", async (req, res) => {
  try { 
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ error: "No userID provided" });

    // Get and decrypt the user's simpleFin credentials, call to simpleFin API, and return the JSON response
    const simpleFinResponse = await fetchSimpleFinData(userID);

    // Ensure that the simpleFinResponse is not empty
    if (!simpleFinResponse.length) return res.status(400).json({ success: false, error: "Error retrieving accounts from simpleFin" });

    // Update balances of existing accounts in the Azure DB
    const acctBalanceUpdateCt = await updateDebitAccountBalances(userID, simpleFinResponse);

    // Add any transactions to the Azure DB
    const insertedTransactionsCt = await importNewTransactions(userID, simpleFinResponse);

    // Set the lastSimpleFinSync time for the user
    await safeQuery(async () => {
      return pool.request()
        .input("userID", sql.VarChar(50), userID)
        .input("lastSync", sql.DateTimeOffset, new Date())
        .query(`
          UPDATE Users
          SET lastSimpleFinSync = @lastSync, updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);
    });

    // Return a message to the user 
    return res.json({ success: true, message: "New SimpleFin data synced to DB. "+acctBalanceUpdateCt+" account balances updated, and "+insertedTransactionsCt+" transactions imported." });
    
  } catch(e) {
    console.error("/sync-simplefin-data returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Get a user
app.get("/load-user", async (req, res) => {
  try {
    const userID = req.query.userID;
    if (!userID) return res.status(400).json({ error: "userID required" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);
    
    // Get user with query
    const result = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.VarChar(50), userID)
      .query(`SELECT * FROM Users WHERE id = @userID`);
    });

    return res.json({ success: true, result: result });

  } catch (e) {
    console.error("/load-user returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Refreshes all of the user data (NOTE: Runs periodically when user is using app to keep app and Azure DB in sync)
app.post("/refresh", async (req, res) => {
  try {
    const { user: clientUser, accounts: clientAccounts, transactions: clientTransactions, transferGroups: clientTransferGroups, lastSuccessfulServerSync } = req.body;
    if (!clientUser.userID) return res.status(400).json({ error: "userID required" });

    // Sync up the client and server information of the user
    const userSync = await syncUser(clientUser);

    // Sync up the client and user information of the user's accounts and import any new accounts
    const accountsSync = await syncDebitAccounts(clientUser.userID, clientAccounts);

    // Sync up the client and user transactions and import any new transactions
    const transactionsSync = await syncTransactions(clientUser.userID, clientTransactions, lastSuccessfulServerSync);

    // Sync up the transfer groups
    const transferGroupsSync = await syncTransferGroups(clientUser.userID, clientTransferGroups, lastSuccessfulServerSync);

    return res.json({
      user: userSync,
      accounts: accountsSync,
      transactions: transactionsSync,
      transferGroups: transferGroupsSync,
      syncTime: new Date().toISOString()
    });
    
  } catch (err) {
    console.error("SYNC USER ERROR:", err);
    res.status(500).json({ error: "Server error" });
  }
});

// Create a transferGroup
app.post("/insert-transfer-group", async (req, res) => {
  try {
    const { tgid, userID, name, transactions: transactions } = req.body;

    if (!tgid || !userID || !name) {
      return res.status(400).json({ error: "Missing required field" });
    }

    const pool = await sql.connect(azureConfig);

    // Insert new transfer group into the Azure DB
    await safeQuery(async () => {
      return pool.request()
      .input("tgid", sql.VarChar(50), tgid)
      .input("userID", sql.VarChar(255), userID)
      .input("name", sql.VarChar(255), name)
      .query(`
        INSERT INTO TransferGroup (
          id, userID, name
        )
        VALUES (@tgid, @userID, @name)
      `);
    });

    // Insert the transfer group id to all of the relevant transactions
    if (transactions && transactions.length) {
      for (const transaction of transactions) {
        await safeQuery(async () => {
          return pool.request()
          .input("tgid", sql.UniqueIdentifier, tgid)
          .input("txid", sql.VarChar(50), transaction.id)
          .input("userID", sql.UniqueIdentifier, userID)
          .query(`
            UPDATE Transactions
            SET 
              transferGroupID = @tgid,
              updatedAt = SYSUTCDATETIME()
            WHERE id = @txid AND userID = @userID
          `);
        });
      }
    }

    res.json({
      success: true,
      message: "Transfer group created and transactions linked",
      tgid
    });

  } catch (e) {
    console.error("/insert-transfer-group returned the following error: ", e);
    res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Get a user's accounts data
app.get("/get-debit-accounts", async (req, res) => {
  try {
    const userID = req.query.userID;
    if (!userID) return res.status(400).json({ error: "userID required" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);
    
    // Get user with query
    const result = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.VarChar(50), userID)
      .query(`SELECT * FROM DebitAccounts WHERE userID = @userID`);
    });

    return res.json({ success: true, result: result });

  } catch (e) {
    console.error("/get-debit-accounts returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Get all user accounts (debit, credit, other)
app.get("/get-all-accounts", async (req, res) => {
  try {
    const userID = req.query.userID; // or req.query.userID if you're using query params
    if (!userID) {
      return res.status(400).json({ success: false, error: "userID required" });
    }

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);

    // Run all three queries safely
    const result = await safeQuery(async () => {
      const debitQuery = pool.request()
        .input("userID", sql.VarChar(50), userID)
        .query(`SELECT * FROM DebitAccounts WHERE userID = @userID`);

      const creditQuery = pool.request()
        .input("userID", sql.VarChar(50), userID)
        .query(`SELECT * FROM CreditAccounts WHERE userID = @userID`);

      const otherQuery = pool.request()
        .input("userID", sql.VarChar(50), userID)
        .query(`SELECT * FROM OtherAccounts WHERE userID = @userID`);

      // Run in parallel for speed
      const [debitResult, creditResult, otherResult] = await Promise.all([
        debitQuery,
        creditQuery,
        otherQuery
      ]);

      return {
        debitAccounts: debitResult.recordset,
        creditAccounts: creditResult.recordset,
        otherAccounts: otherResult.recordset
      };
    });

    return res.json({
      success: true,
      debitAccounts: result.debitAccounts,
      creditAccounts: result.creditAccounts,
      otherAccounts: result.otherAccounts
    });

  } catch (e) {
    console.error("/get-all-accounts returned the following error: ", e);
    return res.status(500).json({
      success: false,
      message: "Server error, please try again later"
    });
  }
});

// Get a user's transactions data
app.get("/get-transactions", async (req, res) => {
  try {
    const userID = req.query.userID;
    if (!userID) return res.status(400).json({ error: "userID required" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);
    
    // Get user with query
    const result = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.VarChar(50), userID)
      .query(`SELECT * FROM Transactions WHERE userID = @userID ORDER BY transactionDate DESC`);
    });

    return res.json({ success: true, result: result });

  } catch (e) {
    console.error("/get-transactions returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Get a user's transfer group data
app.get("/get-transfer-groups", async (req, res) => {
  try {
    const userID = req.query.userID;
    if (!userID) return res.status(400).json({ error: "userID required" });

    // Connect to Azure DB
    const pool = await sql.connect(azureConfig);
    
    // Get user with query
    const result = await safeQuery(async () => {
      return pool.request()
      .input("userID", sql.VarChar(50), userID)
      .query(`SELECT * FROM TransferGroups WHERE userID = @userID`);
    });

    return res.json({ success: true, result: result });

  } catch (e) {
    console.error("/get-transfer-groups returned the following error: ", e);
    return res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Update a user
app.post("/update-user-email", async (req, res) => {
  try {
    const { id, email } = req.body;

    if (!id || !email) {
      return res.status(400).json({ error: "Missing required field" });
    }

    // Update the user's email
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.UniqueIdentifier, id)
      .input("email", sql.VarChar(50), email)
      .query(`
        UPDATE Users
        SET 
          email = @tgid,
          updatedAt = SYSUTCDATETIME()
        WHERE id = @id
      `);
    });

    res.json({success: true, message: "User email updated"});

  } catch (e) {
    console.error("/update-user-email returned the following error: ", e);
    res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Update an account
app.post("/update-debit-account-name", async (req, res) => {

  try {
    const { id, name } = req.body;

    if (!id || !name) {
      return res.status(400).json({ error: "Missing required field" });
    }

    // Update the user's email
    await safeQuery(async () => {
      return pool.request()
      .input("id", sql.UniqueIdentifier, id)
      .input("name", sql.VarChar(255), name)
      .query(`
        UPDATE Users
        SET 
          name = @name,
          updatedAt = SYSUTCDATETIME()
        WHERE id = @id
      `);
    });

    res.json({success: true, message: "Account name updated"});

  } catch (e) {
    console.error("/update-debit-account-name returned the following error: ", e);
    res.status(500).json({ success: false, message: "Server error, please try again later" });
  }
});

// Update a transaction
app.post("/update-transactions", async (req, res) => {

});

// Update a transfer group
app.post("/update-transfer-group", async (req, res) => {

});

// Insert a transfer group


// GET Table endpoints
app.get("/users", async (req, res) => {
    try {
        const pool = await sql.connect(azureConfig);

        const result = await safeQuery(async () => { return pool.request().query("SELECT * FROM dbo.Users") });

        res.json(result.recordset);
    } catch (err) {
        console.error(err);
        res.status(500).send("Database error");
    }
});

app.get("/debitaccounts", async (req, res) => {
    try {
        const pool = await sql.connect(azureConfig);

        const result = await safeQuery(async () => { return pool.request().query("SELECT * FROM dbo.DebitAccounts") });

        res.json(result.recordset);
    } catch (err) {
        console.error(err);
        res.status(500).send("Database error");
    }
});

app.get("/creditaccounts", async (req, res) => {
    try {
        const pool = await sql.connect(azureConfig);

        const result = await safeQuery(async () => { return pool.request().query("SELECT * FROM dbo.CreditAccounts") });

        res.json(result.recordset);
    } catch (err) {
        console.error(err);
        res.status(500).send("Database error");
    }
});

app.get("/transactions", async (req, res) => {
    try {
        const pool = await sql.connect(azureConfig);

        const result = await safeQuery(async () => { return pool.request().query("SELECT * FROM dbo.Transactions ORDER BY transactionDate DESC") });

        res.json(result.recordset);
    } catch (err) {
        console.error(err);
        res.status(500).send("Database error");
    }
});

app.get("/db-health", async (req, res) => {
  try {
    const pool = await sql.connect(azureConfig);

    const result = await safeQuery(async () => { return pool.request().query(`SELECT 1 AS dbAlive`) });

    return res.json({
      success: true,
      dbAlive: true,
      timestamp: new Date().toISOString()
    });

  } catch (err) {
    console.error("DB Health Check Failed:", err);

    return res.status(503).json({
      success: false,
      dbAlive: false,
      error: err.message,
      timestamp: new Date().toISOString()
    });
  }
});