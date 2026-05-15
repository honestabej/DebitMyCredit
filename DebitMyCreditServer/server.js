import 'dotenv/config';
import crypto from "crypto";
import express from "express";
import sql from "mssql";
import cors from "cors";
import axios from "axios";
import bcrypt from "bcryptjs";
import cron from "node-cron";
import jwt from "jsonwebtoken";
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

// JWT Setup
const JWT_SECRET = process.env.JWT_SECRET

// Server steup for testing
const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server running on port ${port}`));

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

function verifyCron(req, res, next) {
  const secret = req.header("x-cron-secret");

  if (!secret || secret !== process.env.CRON_SECRET) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  next();
}

// Uses the JWT to authenticate requests
function authRequired(req, res, next) {
  try {
    const auth = req.header("Authorization") || "";
    const [scheme, token] = auth.split(" ");

    if (scheme !== "Bearer" || !token) {
      return res.status(401).json({ success: false, message: "Missing or invalid Authorization header" });
    }

    const decoded = jwt.verify(token, JWT_SECRET);
    // decoded should contain { id, email } from your existing login/register code
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ success: false, message: "Invalid or expired token" });
  }
}

function toSqlDateTimeOffset(value) {
  const d = new Date(value);
  if (isNaN(d)) return null;

  // Truncate to milliseconds (Tedious-safe)
  d.setMilliseconds(Math.floor(d.getMilliseconds()));
  return d;
}

// This gets the date of 30 days ago and converts it to UNIX time, to be used in the simpleFin API call
function getUnixTime30DaysAgo() {
  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  return Math.floor(thirtyDaysAgo.getTime() / 1000);
}

// Returns the date 30 days ago formatted as YYYY-MM-DD, to be used in the Lunch Flow API call
function getDate30DaysAgo() {
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  return thirtyDaysAgo.toISOString().split('T')[0];
}

// Wrapper for any SQL Query to the DB to handle sleeping DB issues
async function queryWithRetry(callback, options = {}) {
  const maxRetries = options.maxRetries || 3;
  const retryDelay = options.retryDelay || 6000; // 5 seconds (balanced for DB wake-up time)
  const trackAttempts = options.trackAttempts || false; // New option to return attempt count
  
  let lastError;
  
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      console.log(`[DB] Connection attempt ${attempt}/${maxRetries}`);
      
      // Try to connect to the database
      const pool = await sql.connect(azureConfig);
      
      // Execute the callback with the connected pool
      const result = await callback(pool);
      
      console.log(`[DB] Connected successfully on attempt ${attempt}`);

      // If tracking attempts, wrap result with metadata
      if (trackAttempts) {

        return {
          success: true,
          data: result,
          attempts: attempt
        };
      }
      
      return result;
      
    } catch (err) {
      lastError = err;
      
      // Check if it's a connection error
      const isConnectionError = 
        err.code === 'ETIMEOUT' || 
        err.code === 'ESOCKET' ||
        (err.name === 'ConnectionError' && err.message.includes('Failed to connect'));
      
      if (isConnectionError && attempt < maxRetries) {
        console.log(`[DB] Connection failed (attempt ${attempt}/${maxRetries}): ${err.message}`);
        console.log(`[DB] Retrying in ${retryDelay/1000} seconds...`);
        
        // Wait before retrying
        await new Promise(resolve => setTimeout(resolve, retryDelay));
      } else {
        // Either it's not a connection error, or we've exhausted retries
        console.log(`[DB] Database operation failed:`, err.message);
        
        // If tracking attempts, wrap error with metadata
        if (trackAttempts) {
          return {
            success: false,
            error: err,
            attempts: attempt
          };
        }
        
        throw err;
      }
    }
  }
  
  // If we get here, all retries failed
  if (trackAttempts) {
    return {
      success: false,
      error: lastError,
      attempts: maxRetries
    };
  }
  
  throw lastError;
}

// Shared function to sync SimpleFIN data for a single user
async function syncSimpleFinDataForUser(user) {
  // Decrypt the accessURL
  const accessUrl = decrypt({
    data: user.simpleFinAccessURLData,
    iv: user.simpleFinAccessURLIV,
    tag: user.simpleFinAccessURLTag
  });

  // Fetch data from SimpleFIN
  const simpleFinResponse = await axios.get(
    `${accessUrl}/accounts`,
    {
      params: {
        pending: 1,
        include: 'transactions',
        'start-date': getUnixTime30DaysAgo()
      }
    }
  );

  const accounts = simpleFinResponse.data.accounts;
  const simpleFinErrors = simpleFinResponse.data.errors || [];
  console.log(`[SYNC] User ${user.id}: Fetched ${accounts.length} accounts from SimpleFin`);

  // Process accounts and transactions within a database transaction
  const stats = await queryWithRetry(async (pool) => {
    const transaction = new sql.Transaction(pool);
    await transaction.begin();

    let accountsUpdated = 0;
    let accountsAdded = 0;
    let transactionsInserted = 0;
    let pendingTransactionsRemoved = 0;

    try {
      for (const account of accounts) {
        // Get the user's account from DB to check if it exists (lookup by externalID + userID)
        const existingAccountQuery = await new sql.Request(transaction)
          .input("externalId", sql.VarChar(100), account.id)
          .input("userId", sql.UniqueIdentifier, user.id)
          .query(`
            SELECT internalID, balance, availableBalance
            FROM Accounts
            WHERE externalID = @externalId AND userID = @userId
          `);

        // Convert the format of balance, available-balance, and balance-date
        const availableBalance = parseFloat(account["available-balance"]) || 0;
        const balance = parseFloat(account["balance"]) || 0;
        const balanceDate = account["balance-date"]
          ? new Date(account["balance-date"] * 1000)
          : null;

        let accountInternalID;

        // If account doesn't exist in our DB, add it with accountType '-'
        if (existingAccountQuery.recordset.length === 0) {

          // Extract the account number from the name
          const match = account.name.match(/\((\d+)\)/);
          const accountNumber = match ? match[1] : null;
          const cleanedName = account.name.replace(/\s*\(\d+\)/, "").trim();
          accountInternalID = uuidv4();

          await new sql.Request(transaction)
            .input("internalID", sql.UniqueIdentifier, accountInternalID)
            .input("externalID", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, user.id)
            .input("accountSource", sql.NVarChar(255), "SimpleFIN")
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .input("accountType", sql.VarChar(50), '-')
            .query(`
              INSERT INTO Accounts (
                internalID, externalID, userID, name, bank, accountSource, accountNumber, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt
              )
              VALUES (
                @internalID, @externalID, @userID, @name, @bank, @accountSource, @accountNumber, @availableBalance, @balance, @balanceDate, @accountType, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          accountsAdded++;
        } else {
          accountInternalID = existingAccountQuery.recordset[0].internalID;
          await new sql.Request(transaction)
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              UPDATE Accounts
              SET availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHERE internalID = @accountInternalID
            `);
          accountsUpdated++;
        }

        // If account is new or balances changed, add a new accountBalanceHistory row
        const isNew = existingAccountQuery.recordset.length === 0;
        const existing = isNew ? null : existingAccountQuery.recordset[0];
        const balanceChanged = isNew || parseFloat(existing.balance) !== balance || parseFloat(existing.availableBalance) !== availableBalance;

        if (balanceChanged) {
          await new sql.Request(transaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              INSERT INTO AccountBalanceHistory (
                id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
              )
              VALUES (
                @id, @accountInternalID, @availableBalance, @balance, @balanceDate, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);
        }

        // Insert transactions
        const simpleFinTxnIds = account.transactions
          ? account.transactions.map(txn => txn.id)
          : [];

        // Remove orphaned pending transactions (lookup by accountInternalID)
        const orphanedTxns = await new sql.Request(transaction)
          .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
          .query(`
            SELECT internalID, externalID
            FROM Transactions
            WHERE accountInternalID = @accountInternalID AND pending = 1
          `);

        for (const dbTxn of orphanedTxns.recordset) {
          if (!simpleFinTxnIds.includes(dbTxn.externalID)) {
            await new sql.Request(transaction)
              .input("txnInternalID", sql.UniqueIdentifier, dbTxn.internalID)
              .query(`DELETE FROM Transactions WHERE internalID = @txnInternalID`);

            pendingTransactionsRemoved++;
          }
        }

        // Insert/update transactions
        if (account.transactions) {
          // console.log(`[SYNC:SimpleFIN] Account "${account.name || account.id}" has ${account.transactions.length} transactions from SimpleFIN:`);
          // account.transactions.forEach(txn => {
          //   const txnDate = txn.posted ? new Date(txn.posted * 1000).toISOString() : 'no date';
          //   console.log(`  - [${txnDate}] "${txn.payee || 'Unknown'}" $${txn.amount} (id: ${txn.id}, pending: ${txn.pending || false})`);
          // });

          for (const txn of account.transactions) {
            const existingTxn = await new sql.Request(transaction)
              .input("txnExternalId", sql.VarChar(100), txn.id)
              .input("txnUserID", sql.UniqueIdentifier, user.id)
              .query(`SELECT internalID, pending FROM Transactions WHERE externalID = @txnExternalId AND userID = @txnUserID`);

            const txnDate = txn.posted
              ? new Date(txn.posted * 1000)
              : new Date();

            if (existingTxn.recordset.length === 0) {
              console.log(`  [SYNC:SimpleFIN] INSERT new txn: "${txn.payee || 'Unknown'}" ${txnDate.toISOString()}`);
              // Insert new transaction
              await new sql.Request(transaction)
                .input("internalID", sql.UniqueIdentifier, uuidv4())
                .input("externalID", sql.VarChar(100), txn.id)
                .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
                .input("userID", sql.UniqueIdentifier, user.id)
                .input("amount", sql.Decimal(18, 2), parseFloat(txn.amount) || 0)
                .input("name", sql.NVarChar(500), txn.payee || 'Unknown')
                .input("notes", sql.NVarChar(500), txn.description || '')
                .input("transactionDate", sql.DateTimeOffset, txnDate)
                .input("pending", sql.Bit, txn.pending || false)
                .query(`
                  INSERT INTO Transactions (
                    internalID, externalID, accountInternalID, userID, amount, name, notes,
                    transactionDate, pending, createdAt, updatedAt
                  )
                  VALUES (
                    @internalID, @externalID, @accountInternalID, @userID, @amount, @name, @notes,
                    @transactionDate, @pending, SYSUTCDATETIME(), SYSUTCDATETIME()
                  )
                `);

              transactionsInserted++;
            } else {
              // Update if pending status changed
              const existingPending = existingTxn.recordset[0].pending;
              const newPending = txn.pending || false;

              if (existingPending !== newPending) {
                await new sql.Request(transaction)
                  .input("txnInternalID", sql.UniqueIdentifier, existingTxn.recordset[0].internalID)
                  .input("pending", sql.Bit, newPending)
                  .input("transactionDate", sql.DateTimeOffset, txnDate)
                  .query(`
                    UPDATE Transactions
                    SET pending = @pending,
                        transactionDate = @transactionDate,
                        updatedAt = SYSUTCDATETIME()
                    WHERE internalID = @txnInternalID
                  `);
              }
            }
          }
        }
      }

      await transaction.commit();
      return { accountsUpdated, accountsAdded, transactionsInserted, pendingTransactionsRemoved, errors: simpleFinErrors };

    } catch (dbErr) {
      await transaction.rollback();
      throw dbErr;
    }
  });

  console.log(`[SYNC] User ${user.id}: SimpleFIN sync complete - ${stats.accountsUpdated} accounts updated, ${stats.accountsAdded} accounts added, ${stats.transactionsInserted} transactions inserted, ${stats.pendingTransactionsRemoved} pending transactions removed`);

  return stats;
}

// Shared function to sync Lunch Flow data for a single user
async function syncLunchFlowDataForUser(user) {
  const lunchFlowBaseURL = "https://www.lunchflow.app/api/v1";

  // Decrypt the API key
  const apiKey = decrypt({
    data: user.lunchFlowAPIKeyData,
    iv: user.lunchFlowAPIKeyIV,
    tag: user.lunchFlowAPIKeyTag
  });

  // Fetch accounts from Lunch Flow
  const lfResponse = await fetch(`${lunchFlowBaseURL}/accounts`, {
    method: "GET",
    headers: { "x-api-key": apiKey }
  });

  if (!lfResponse.ok) {
    throw new Error(`Lunch Flow API error: ${lfResponse.status}`);
  }

  const body = await lfResponse.json();
  const accounts = body.accounts || body || [];

  console.log(`[SYNC] User ${user.id}: Fetched ${accounts.length} accounts from Lunch Flow`);

  // Fetch balances and transactions for all accounts in parallel
  const [balanceResults, transactionResults] = await Promise.all([
    Promise.all(
      accounts.map(account =>
        fetch(`${lunchFlowBaseURL}/accounts/${account.id}/balance`, {
          method: "GET",
          headers: { "x-api-key": apiKey }
        })
        .then(res => {
          if (!res.ok) throw new Error(`Balance fetch failed: ${res.status}`);
          return res.json();
        })
        .then(balanceData => ({ accountId: account.id, balanceData }))
      )
    ),
    Promise.all(
      accounts.map(account =>
        fetch(`${lunchFlowBaseURL}/accounts/${account.id}/transactions?from=${getDate30DaysAgo()}&include_pending=true`, {
          method: "GET",
          headers: { "x-api-key": apiKey }
        })
        .then(res => {
          if (!res.ok) throw new Error(`Transactions fetch failed: ${res.status}`);
          return res.json();
        })
        .then(data => ({ accountId: account.id, transactions: data.transactions || [] }))
      )
    )
  ]);

  const balanceMap = new Map(balanceResults.map(b => [b.accountId, b.balanceData]));
  const transactionMap = new Map(transactionResults.map(t => [t.accountId, t.transactions]));

  const stats = await queryWithRetry(async (pool) => {
    const transaction = new sql.Transaction(pool);
    await transaction.begin();

    let accountsUpdated = 0;
    let accountsAdded = 0;
    let transactionsInserted = 0;
    let pendingTransactionsRemoved = 0;

    try {
      for (const account of accounts) {
        const balanceData = balanceMap.get(account.id);
        const rawBalance =
          balanceData?.balance ??
          balanceData?.current_balance ??
          balanceData?.amount ??
          0;
        const balance = parseFloat(rawBalance?.amount ?? rawBalance) || 0;

        // Lookup by externalID + userID
        const existingAccountQuery = await new sql.Request(transaction)
          .input("externalId", sql.VarChar(100), String(account.id))
          .input("userId", sql.UniqueIdentifier, user.id)
          .query(`
            SELECT internalID, balance, availableBalance
            FROM Accounts
            WHERE externalID = @externalId AND userID = @userId
          `);

        let accountInternalID;

        if (existingAccountQuery.recordset.length === 0) {
          // Insert new account
          accountInternalID = uuidv4();
          await new sql.Request(transaction)
            .input("internalID", sql.UniqueIdentifier, accountInternalID)
            .input("externalID", sql.VarChar(100), String(account.id))
            .input("userID", sql.UniqueIdentifier, user.id)
            .input("name", sql.NVarChar(255), account.name || "Unnamed")
            .input("bank", sql.NVarChar(255), account.institution_name || null)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("availableBalance", sql.Decimal(18, 2), balance)
            .query(`
              INSERT INTO Accounts (
                internalID, externalID, userID, name, bank, accountSource,
                availableBalance, balance, balanceDate,
                accountType, createdAt, updatedAt
              )
              VALUES (
                @internalID, @externalID, @userID, @name, @bank, 'Lunch Flow',
                @availableBalance, @balance, SYSUTCDATETIME(),
                '-', SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          // Record initial balance history
          await new sql.Request(transaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("availableBalance", sql.Decimal(18, 2), balance)
            .query(`
              INSERT INTO AccountBalanceHistory (
                id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
              )
              VALUES (
                @id, @accountInternalID, @availableBalance, @balance, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          accountsAdded++;

        } else {
          // Update existing account
          accountInternalID = existingAccountQuery.recordset[0].internalID;
          const existing = existingAccountQuery.recordset[0];
          const balanceChanged =
            parseFloat(existing.balance) !== balance ||
            parseFloat(existing.availableBalance) !== balance;

          if (balanceChanged) {
            await new sql.Request(transaction)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                UPDATE Accounts
                SET balance = @balance,
                    availableBalance = @availableBalance,
                    balanceDate = SYSUTCDATETIME(),
                    updatedAt = SYSUTCDATETIME()
                WHERE internalID = @accountInternalID
              `);

            await new sql.Request(transaction)
              .input("id", sql.UniqueIdentifier, uuidv4())
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                INSERT INTO AccountBalanceHistory (
                  id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
                )
                VALUES (
                  @id, @accountInternalID, @availableBalance, @balance, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              `);
          } else {
            await new sql.Request(transaction)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                UPDATE Accounts
                SET balance = @balance,
                    availableBalance = @availableBalance,
                    updatedAt = SYSUTCDATETIME()
                WHERE internalID = @accountInternalID
              `);
          }

          accountsUpdated++;
        }

        // Sync transactions for this account
        const lfTxns = transactionMap.get(account.id) || [];
        const lfTxnIds = lfTxns.map(txn => String(txn.id));

        // Remove orphaned pending transactions no longer in the Lunch Flow response
        const orphanedTxns = await new sql.Request(transaction)
          .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
          .query(`
            SELECT internalID, externalID
            FROM Transactions
            WHERE accountInternalID = @accountInternalID AND pending = 1
          `);

        for (const dbTxn of orphanedTxns.recordset) {
          if (!lfTxnIds.includes(dbTxn.externalID)) {
            await new sql.Request(transaction)
              .input("txnInternalID", sql.UniqueIdentifier, dbTxn.internalID)
              .query(`DELETE FROM Transactions WHERE internalID = @txnInternalID`);

            pendingTransactionsRemoved++;
          }
        }

        // // Insert/update transactions
        // console.log(`[SYNC:LunchFlow] Account "${account.name || account.id}" has ${lfTxns.length} transactions from Lunch Flow:`);
        // lfTxns.forEach(txn => {
        //   const txnDate = txn.date ? new Date(txn.date).toISOString() : 'no date';
        //   console.log(`  - [${txnDate}] "${txn.merchant || 'Unknown'}" $${txn.amount} (id: ${txn.id}, pending: ${txn.isPending || false})`);
        // });

        for (const txn of lfTxns) {
          if (!txn.id) continue;

          const txnExternalId = String(txn.id);
          const txnDate = txn.date ? new Date(txn.date) : new Date();
          const isPending = txn.isPending || false;

          const existingTxn = await new sql.Request(transaction)
            .input("txnExternalId", sql.VarChar(100), txnExternalId)
            .input("txnUserID", sql.UniqueIdentifier, user.id)
            .query(`SELECT internalID, pending FROM Transactions WHERE externalID = @txnExternalId AND userID = @txnUserID`);

          if (existingTxn.recordset.length === 0) {
            console.log(`  [SYNC:LunchFlow] INSERT new txn: "${txn.merchant || 'Unknown'}" ${txnDate.toISOString()}`);
            await new sql.Request(transaction)
              .input("internalID", sql.UniqueIdentifier, uuidv4())
              .input("externalID", sql.VarChar(100), txnExternalId)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("userID", sql.UniqueIdentifier, user.id)
              .input("amount", sql.Decimal(18, 2), parseFloat(txn.amount) || 0)
              .input("name", sql.NVarChar(500), txn.merchant || "Unknown")
              .input("notes", sql.NVarChar(500), txn.description || "")
              .input("transactionDate", sql.DateTimeOffset, txnDate)
              .input("pending", sql.Bit, isPending)
              .query(`
                INSERT INTO Transactions (
                  internalID, externalID, accountInternalID, userID, amount, name, notes,
                  transactionDate, pending, createdAt, updatedAt
                )
                VALUES (
                  @internalID, @externalID, @accountInternalID, @userID, @amount, @name, @notes,
                  @transactionDate, @pending, SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              `);

            transactionsInserted++;
          } else {
            // Update if pending status changed
            const existingPending = existingTxn.recordset[0].pending;

            if (existingPending !== isPending) {
              await new sql.Request(transaction)
                .input("txnInternalID", sql.UniqueIdentifier, existingTxn.recordset[0].internalID)
                .input("pending", sql.Bit, isPending)
                .input("transactionDate", sql.DateTimeOffset, txnDate)
                .query(`
                  UPDATE Transactions
                  SET pending = @pending,
                      transactionDate = @transactionDate,
                      updatedAt = SYSUTCDATETIME()
                  WHERE internalID = @txnInternalID
                `);
            }
          }
        }
      }

      await transaction.commit();
      return { accountsUpdated, accountsAdded, transactionsInserted, pendingTransactionsRemoved };

    } catch (dbErr) {
      await transaction.rollback();
      throw dbErr;
    }
  });

  console.log(`[SYNC] User ${user.id}: Lunch Flow sync complete - ${stats.accountsUpdated} accounts updated, ${stats.accountsAdded} accounts added, ${stats.transactionsInserted} transactions inserted, ${stats.pendingTransactionsRemoved} pending transactions removed`);

  return stats;
}

/*****************************************
 * API Endpoints
 *****************************************/
app.get("/status", async (req, res, next) => {
  try {
    // Server is always "up" if we can respond
    const serverStatus = {
      status: "up",
      timestamp: new Date().toISOString()
    };

    const startTime = Date.now();

    // Use queryWithRetry with attempt tracking enabled
    const dbResult = await queryWithRetry(
      async (pool) => {
        await pool.request().query('SELECT 1 AS healthCheck');
        return true; // Just return success indicator
      },
      {
        maxRetries: 3,
        retryDelay: 5000, // 5 seconds for health checks
        trackAttempts: true // Enable attempt tracking
      }
    );

    const responseTime = Date.now() - startTime;

    // Build database status from the result
    let dbStatus;
    
    if (dbResult.success) {
      dbStatus = {
        status: "up",
        message: dbResult.attempts === 1 
          ? "Connected immediately" 
          : `Connected after ${dbResult.attempts} attempts`,
        responseTime: `${responseTime}ms`,
        attempts: dbResult.attempts
      };
    } else {
      dbStatus = {
        status: "down",
        message: dbResult.error?.code === 'ETIMEOUT' || dbResult.error?.name === 'ConnectionError'
          ? `Database unreachable after ${dbResult.attempts} attempts`
          : "Database error occurred",
        responseTime: `${responseTime}ms`,
        attempts: dbResult.attempts,
        error: dbResult.error?.message
      };
    }

    // Return overall status
    res.json({
      server: serverStatus,
      database: dbStatus,
      overall: dbStatus.status === "up" ? "healthy" : "degraded"
    });

  } catch (err) {
    next(err);
  }
})

app.get("/test", async (req, res, next) => {
  try {
    const { userID } = req.query;
    
    if (!userID) {
      return res.status(400).json({ 
        success: false,
        message: "userID required as query parameter"
      });
    }

    const result = await queryWithRetry(async (pool) => {
      const queryResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT 
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag
          FROM Users
          WHERE id = @userID
        `);

      if (queryResult.recordset.length === 0) {
        return { found: false };
      }

      const user = queryResult.recordset[0];
      
      // Check if SimpleFin data exists
      if (!user.simpleFinAccessURLData || !user.simpleFinAccessURLIV || !user.simpleFinAccessURLTag) {
        return { 
          found: true, 
          hasSimpleFin: false 
        };
      }

      // Decrypt the access URL
      const accessUrl = decrypt({
        data: user.simpleFinAccessURLData,
        iv: user.simpleFinAccessURLIV,
        tag: user.simpleFinAccessURLTag
      });

      return {
        found: true,
        hasSimpleFin: true,
        accessUrl
      };
    });

    // Handle results
    if (!result.found) {
      return res.status(404).json({
        success: false,
        message: "User not found"
      });
    }

    if (!result.hasSimpleFin) {
      return res.json({
        success: true,
        message: "User has no SimpleFin connection",
        accessUrl: null
      });
    }

    const accountResponse = await axios.get(`${result.accessUrl}/accounts`);

    res.json({
      success: true,
      accessUrl: result.accessUrl,
      accounts: accountResponse.data.accounts
    });

  } catch (err) {
    next(err);
  }
})

// Internal call from GitHub action to keep DB up to date
app.post("/internal/sync-connected-bank-data", verifyCron, async (req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all users that have at least one connected service
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE (simpleFinAccessURLData IS NOT NULL AND simpleFinAccessURLIV IS NOT NULL AND simpleFinAccessURLTag IS NOT NULL)
             OR (lunchFlowAPIKeyData IS NOT NULL AND lunchFlowAPIKeyIV IS NOT NULL AND lunchFlowAPIKeyTag IS NOT NULL)
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with connected accounts`);

    // Process each user using shared sync functions
    for (const user of usersWithAccess) {
      try {
        const hasSimpleFin = user.simpleFinAccessURLData && user.simpleFinAccessURLIV && user.simpleFinAccessURLTag;
        const hasLunchFlow = user.lunchFlowAPIKeyData && user.lunchFlowAPIKeyIV && user.lunchFlowAPIKeyTag;

        const [simpleFinStats, lunchFlowStats] = await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
        ]);

        usersProcessed++;

        for (const stats of [simpleFinStats, lunchFlowStats]) {
          if (!stats) continue;
          totalAccountsUpdated += stats.accountsUpdated;
          totalAccountsAdded += stats.accountsAdded;
          totalTransactionsInserted += stats.transactionsInserted;
          totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;
        }

      } catch (userErr) {
        console.error(`[SYNC] Error processing user ${user.id}:`, userErr.message);
        errors.push({
          userId: user.id,
          error: userErr.message
        });
      }
    }

    res.json({
      success: true,
      message: `Sync complete: ${usersProcessed} users processed`,
      stats: {
        usersProcessed,
        totalAccountsUpdated,
        totalAccountsAdded,
        totalTransactionsInserted,
        totalPendingTransactionsRemoved,
        errors: errors.length > 0 ? errors : undefined
      }
    });

  } catch (err) {
    next(err);
  }
});

app.post("/manual/sync-connected-bank-data", async (_req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all users that have at least one connected service
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE (simpleFinAccessURLData IS NOT NULL AND simpleFinAccessURLIV IS NOT NULL AND simpleFinAccessURLTag IS NOT NULL)
             OR (lunchFlowAPIKeyData IS NOT NULL AND lunchFlowAPIKeyIV IS NOT NULL AND lunchFlowAPIKeyTag IS NOT NULL)
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with connected accounts`);

    // Process each user using shared sync functions
    for (const user of usersWithAccess) {
      try {
        const hasSimpleFin = user.simpleFinAccessURLData && user.simpleFinAccessURLIV && user.simpleFinAccessURLTag;
        const hasLunchFlow = user.lunchFlowAPIKeyData && user.lunchFlowAPIKeyIV && user.lunchFlowAPIKeyTag;

        const [simpleFinStats, lunchFlowStats] = await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
        ]);

        usersProcessed++;

        for (const stats of [simpleFinStats, lunchFlowStats]) {
          if (!stats) continue;
          totalAccountsUpdated += stats.accountsUpdated;
          totalAccountsAdded += stats.accountsAdded;
          totalTransactionsInserted += stats.transactionsInserted;
          totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;
        }

      } catch (userErr) {
        console.error(`[SYNC] Error processing user ${user.id}:`, userErr.message);
        errors.push({
          userId: user.id,
          error: userErr.message
        });
      }
    }

    res.json({
      success: true,
      message: `Sync complete: ${usersProcessed} users processed`,
      stats: {
        usersProcessed,
        totalAccountsUpdated,
        totalAccountsAdded,
        totalTransactionsInserted,
        totalPendingTransactionsRemoved,
        errors: errors.length > 0 ? errors : undefined
      }
    });

  } catch (err) {
    next(err);
  }
})

// Register a new user
app.post("/register", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    // Hash password and generate userID BEFORE the database call
    const hashed = await hashPassword(password);
    const id = uuidv4();
    const tgid = uuidv4();

    // Wrap ALL database operations in the retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Check if email already exists
      const existing = await pool.request()
        .input("email", sql.VarChar(255), email)
        .query(`SELECT id FROM Users WHERE email = @email`);

      if (existing.recordset.length > 0) {
        return { emailExists: true };
      }

      // Insert new user into the Azure DB
      await pool.request()
        .input("id", sql.VarChar(50), id)
        .input("email", sql.VarChar(255), email)
        .input("passwordHash", sql.VarChar(255), hashed)
        .query(`
          INSERT INTO Users (
            id, email, passwordHash
          )
          VALUES (@id, @email, @passwordHash)
        `);

      // Create a "Manual" transfer group by default for all users
      await pool.request()
        .input("tgid", sql.VarChar(50), tgid)
        .input("userID", sql.VarChar(50), id)
        .input("name", sql.VarChar(255), "Manual")
        .query(`
          INSERT INTO TransferGroups (id, userID, name)
          VALUES (@tgid, @userID, @name)
        `);

      // Fetch the newly created user to return to the client
      const newUserResult = await pool.request()
        .input("id", sql.VarChar(50), id)
        .query(`
          SELECT 
            id, email, createdAt, updatedAt
          FROM Users
          WHERE id = @id
        `);

      return { 
        emailExists: false,
        user: newUserResult.recordset[0]
      };
    });

    // Handle the result OUTSIDE the wrapper
    if (result.emailExists) {
      console.log(`[REGISTER] Registration failed - email already exists: ${email}`);
      return res.status(409).json({
        success: false,
        error: "Email already exists"
      });
    }

    // Generate JWT
    const token = jwt.sign({ id: result.user.id, email: result.user.email }, JWT_SECRET);

    console.log(`[REGISTER] New user registered: ${result.user.id} (${email})`);
    res.json({
      success: true,
      message: `New user registered`,
      token,
      user: result.user
    });

  } catch (err) {
    next(err);
  }
});

// Login an existing user with email/password
app.post("/login", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) return res.status(400).json({ success: false, error: "Missing fields" });
    
    // Use the database retry wrapper
    const result = await queryWithRetry(async (pool) => {
      const queryResult = await pool.request()
        .input("email", sql.VarChar(255), email)
        .query(`
          SELECT id, email, simpleFinAccessURLData, lunchFlowAPIKeyData, createdAt, updatedAt, passwordHash
          FROM Users
          WHERE email = @email
        `);

      if (queryResult.recordset.length === 0) {
        return { found: false };
      }

      const user = queryResult.recordset[0];
      const valid = await bcrypt.compare(password, user.passwordHash);

      // Check if credentials are set for each service
      const simpleFINConnected = user.simpleFinAccessURLData != null && user.simpleFinAccessURLData !== '';
      const lunchFlowConnected = user.lunchFlowAPIKeyData != null && user.lunchFlowAPIKeyData !== '';

      // Remove sensitive fields before returning
      delete user.simpleFinAccessURLData;
      delete user.lunchFlowAPIKeyData;
      delete user.passwordHash;

      if (!valid) {
        return { found: true, valid: false };
      }

      // Generate JWT
      const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET);

      return {
        found: true,
        valid: true,
        token,
        user: { ...user, simpleFINConnected, lunchFlowConnected }
      };
    });

    // Handle the result
    if (!result.found) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    if (!result.valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    const responseData = { 
      success: true, 
      token: result.token,
      user: result.user
    };
    
    // console.log("Final response user object:", JSON.stringify(result.user, null, 2));

    return res.json(responseData);

  } catch (err) {
    next(err);
  }
});

// Connect the User's SimpleFin account
app.post("/connect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID, credential } = req.body;
    if (!userID || !credential) return res.status(400).json({
      success: false,
      message: "userID and setup token required",
      accounts: null
    });

    // Decode setup token into claim url
    let claimUrl;
    try {
      claimUrl = Buffer.from(credential, "base64").toString("utf-8");
    } catch {
      return res.status(400).json({
        success: false,
        message: "Invalid setup token format",
        accounts: null
      });
    }

    // Get access url
    let accessUrl;
    try {
      const claimResponse = await axios.post(claimUrl);
      accessUrl = claimResponse.data;

      if (!accessUrl || typeof accessUrl !== "string") {
        throw new Error("Invalid claim response");
      } 
    } catch (err) {
      return res.status(400).json({
        success: false,
        message: "Failed to claim SimpleFIN token (may be expired or already used)",
        accounts: null
      });
    }

    // Fetch user's connected accounts from SimpleFIN
    let accounts;
    try {
      const accountResponse = await axios.get(`${accessUrl}/accounts`);
      accounts = accountResponse.data.accounts;
    } catch (err) {
      return res.status(500).json({
        success: false,
        message: "Failed to fetch accounts from SimpleFIN",
        accounts: null
      });
    }

    // Encrypt the access url before storing it in the database
    const accessEnc = encrypt(accessUrl);

    // Wrap ALL database operations (including transaction) in the retry wrapper
    const userAccounts = await queryWithRetry(async (pool) => {
      // Begin transaction
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      try {
        // Store access URL in Users table
        await new sql.Request(transaction)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("data", sql.VarChar(sql.MAX), accessEnc.data)
          .input("iv", sql.VarChar(32), accessEnc.iv)
          .input("tag", sql.VarChar(32), accessEnc.tag)
          .query(`
            UPDATE Users
            SET simpleFinAccessURLData = @data,
                simpleFinAccessURLIV = @iv,
                simpleFinAccessURLTag = @tag,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @userID
          `);

        // Upsert accounts (MERGE on externalID + userID to support multiple users connecting to the same bank account)
        for (const account of accounts) {
          // Format the balance-date correctly
          const balanceDate = account["balance-date"]
            ? new Date(account["balance-date"] * 1000)
            : null;

          // Extract the account number from the name
          const match = account.name.match(/\((\d+)\)/);
          const accountNumber = match ? match[1] : null;
          const cleanedName = account.name.replace(/\s*\(\d+\)/, "").trim();

          await new sql.Request(transaction)
            .input("externalID", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("availableBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
            .input("balance", sql.Decimal(18, 2), parseFloat(account["balance"]) || 0)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              MERGE Accounts WITH (HOLDLOCK) AS target
              USING (SELECT @externalID AS externalID, @userID AS userID) AS source
                ON target.externalID = source.externalID AND target.userID = source.userID
              WHEN MATCHED THEN
                UPDATE SET
                  bank = @bank,
                  accountNumber = @accountNumber,
                  availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN
                INSERT (internalID, externalID, userID, name, bank, accountSource, accountNumber, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt)
                VALUES (NEWID(), @externalID, @userID, @name, @bank, 'SimpleFIN', @accountNumber, @availableBalance, @balance, @balanceDate, '-', SYSUTCDATETIME(), SYSUTCDATETIME());
            `);
        }

        await transaction.commit();

        // After all updates, fetch all accounts for this user
        const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`SELECT 
              internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt 
              FROM Accounts WHERE userID = @userID AND accountSource = 'SimpleFIN'`);

        // Return the accounts data
        return result.recordset;

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }
    });

    // Send response OUTSIDE the wrapper
    return res.json({
      success: true,
      message: "SimpleFIN connected successfully",
      accounts: userAccounts
    });

  } catch (err) {
    next(err);
  } 
});

// Disconnect a User's SimpleFIN account
app.post("/disconnect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ 
      success: false,
      message: "userID required"
    });

    // Wrap database operations in retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Query the DB to set the SimpleFIN data to NULL
      const updateResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE Users
          SET simpleFinAccessURLData = NULL,
              simpleFinAccessURLIV = NULL,
              simpleFinAccessURLTag = NULL,
              updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);

      // Delete accounts associated with SimpleFIN
      await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          DELETE FROM Accounts
          WHERE userID = @userID AND accountSource = 'SimpleFIN'
        `);

      return { rowsAffected: updateResult.rowsAffected[0] };
    });
    
    // Check result OUTSIDE the wrapper
    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "User not found or already disconnected"
      });
    }

    res.json({
      success: true,
      message: "SimpleFIN account disconnected"
    });

  } catch (err) {
    next(err);
  } 
});

// Connect the User's Lunch Flow account
app.post("/connect-lunchflow", async (req, res, next) => {
  try {
    // Get id and api key from user
    const { userID, credential } = req.body;
    if (!userID || !credential) return res.status(400).json({ 
      success: false,
      message: "userID and api key required",
      accounts: null
    });

    // Ensure API Key works and get the accounts
    const lunchFlowBaseURL = "https://www.lunchflow.app/api/v1"

    const lfResponse = await fetch(`${lunchFlowBaseURL}/accounts`, {
      method: "GET",
      headers: {
        "x-api-key": credential
      }
    });

    if (!lfResponse.ok) {
      throw new Error(`Lunch Flow API error: ${lfResponse.status}`);
    }

    const body = await lfResponse.json();
    const accounts = body.accounts || body || [];

    // Get the balances of all accounts in parallel
    const balancePromises = accounts.map(account =>
      fetch(`${lunchFlowBaseURL}/accounts/${account.id}/balance`, {
        method: "GET",
        headers: {
          "x-api-key": credential
        }
      })
      .then(res => {
        if (!res.ok) throw new Error(`Balance fetch failed: ${res.status}`);
        return res.json();
      })
      .then(balanceData => ({
        accountId: account.id,
        balanceData
      }))
    );

    const balanceResults = await Promise.all(balancePromises);

    // Add the balance info to each account
    const balanceMap = new Map(
      balanceResults.map(b => [b.accountId, b.balanceData])
    );

    for (const account of accounts) {
      const balanceData = balanceMap.get(account.id);

      // Adjust based on actual API response shape
      const balanceValue =
        balanceData?.balance ??
        balanceData?.current_balance ??
        balanceData?.amount ??
        0;

      account.availableBalance = balanceValue;
      account.balance = balanceValue;
    }

    // Encrypt the api key before storing it in the database
    const accessEnc = encrypt(credential);
    
    const userAccounts = await queryWithRetry(async (pool) => {
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      try {
        // Store encrypted API key
        await new sql.Request(transaction)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("data", sql.VarChar(sql.MAX), accessEnc.data)
          .input("iv", sql.VarChar(32), accessEnc.iv)
          .input("tag", sql.VarChar(32), accessEnc.tag)
          .query(`
            UPDATE Users
            SET lunchFlowAPIKeyData = @data,
                lunchFlowAPIKeyIV = @iv,
                lunchFlowAPIKeyTag = @tag,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @userID
          `);

        // Upsert accounts (MERGE on externalID + userID to support multiple users per bank account)
        for (const account of accounts) {
          const cleanedName = account.name || "Unnamed";

          await new sql.Request(transaction)
            .input("externalID", sql.VarChar(100), String(account.id))
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.institution_name || null)
            .input("availableBalance", sql.Decimal(18, 2), parseFloat(account.availableBalance?.amount ?? account.availableBalance) || 0)
            .input("balance", sql.Decimal(18, 2), parseFloat(account.balance?.amount ?? account.balance) || 0)
            .query(`
              MERGE Accounts WITH (HOLDLOCK) AS target
              USING (SELECT @externalID AS externalID, @userID AS userID) AS source
                ON target.externalID = source.externalID AND target.userID = source.userID
              WHEN MATCHED THEN
                UPDATE SET
                  bank = @bank,
                  availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = SYSUTCDATETIME(),
                  updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN
                INSERT (internalID, externalID, userID, name, bank, accountSource, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt)
                VALUES (NEWID(), @externalID, @userID, @name, @bank, 'Lunch Flow', @availableBalance, @balance, SYSUTCDATETIME(), '-', SYSUTCDATETIME(), SYSUTCDATETIME());
            `);
        }

        await transaction.commit();

        const result = await pool.request()
          .input("userID", sql.UniqueIdentifier, userID)
          .query(`
            SELECT internalID AS id, externalID, name, bank, accountSource,
                   availableBalance, balance,
                   accountType, createdAt, updatedAt
            FROM Accounts
            WHERE userID = @userID AND accountSource = 'Lunch Flow'
          `);

        return result.recordset;

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }

    });

    return res.json({
      success: true,
      message: "Lunch Flow connected successfully",
      accounts: userAccounts

    });

  } catch (err) {
    next(err);
  } 
});

// Disconnect a User's Lunch Flow account
app.post("/disconnect-lunchflow", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ 
      success: false,
      message: "userID required"
    });

    // Wrap database operations in retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Query the DB to set the Lunch Flow data to NULL
      const updateResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE Users
          SET lunchFlowAPIKeyData = NULL,
              lunchFlowAPIKeyIV = NULL,
              lunchFlowAPIKeyTag = NULL,
              updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);

      // Delete accounts associated with Lunch Flow
      await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          DELETE FROM Accounts
          WHERE userID = @userID AND accountSource = 'Lunch Flow'
        `);

      return { rowsAffected: updateResult.rowsAffected[0] };
    });
    
    // Check result OUTSIDE the wrapper
    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "User not found or already disconnected"
      });
    }

    res.json({
      success: true,
      message: "SimpleFIN account disconnected"
    });

  } catch (err) {
    next(err);
  } 
});

// Add a new manual account
app.post("/add-manual-account", async (req, res, next) => {
  try {
    const { userID, name, balance, bank, accountNumber, availableBalance, accountType, createdAt, updatedAt } = req.body;

    if (!userID || !name || balance === undefined || !createdAt || !updatedAt) {
      return res.status(400).json({
        success: false,
        message: "userID, name, balance, createdAt, and updatedAt are required"
      });
    }

    const account = await queryWithRetry(async (pool) => {
      const internalID = uuidv4();
      const externalID = internalID; // No external source for manual accounts
      const resolvedAvailableBalance = availableBalance ?? balance;

      await pool.request()
        .input("internalID", sql.UniqueIdentifier, internalID)
        .input("externalID", sql.VarChar(100), externalID)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), name)
        .input("bank", sql.NVarChar(255), bank || null)
        .input("accountNumber", sql.Char(6), accountNumber || null)
        .input("balance", sql.Decimal(18, 2), balance)
        .input("availableBalance", sql.Decimal(18, 2), resolvedAvailableBalance)
        .input("accountType", sql.VarChar(50), accountType || null)
        .input("createdAt", sql.DateTimeOffset, createdAt)
        .input("updatedAt", sql.DateTimeOffset, updatedAt)
        .query(`
          INSERT INTO Accounts (
            internalID, externalID, userID, name, bank, accountSource,
            accountNumber, availableBalance, balance, balanceDate,
            accountType, createdAt, updatedAt
          )
          VALUES (
            @internalID, @externalID, @userID, @name, @bank, 'Manual',
            @accountNumber, @availableBalance, @balance, @createdAt,
            @accountType, @createdAt, @updatedAt
          )
        `);

      // Record initial balance history
      await pool.request()
        .input("id", sql.UniqueIdentifier, uuidv4())
        .input("accountInternalID", sql.UniqueIdentifier, internalID)
        .input("balance", sql.Decimal(18, 2), balance)
        .input("availableBalance", sql.Decimal(18, 2), resolvedAvailableBalance)
        .input("createdAt", sql.DateTimeOffset, createdAt)
        .input("updatedAt", sql.DateTimeOffset, updatedAt)
        .query(`
          INSERT INTO AccountBalanceHistory (
            id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
          )
          VALUES (
            @id, @accountInternalID, @availableBalance, @balance, @createdAt, @createdAt, @updatedAt
          )
        `);

      // Return the newly created account
      const result = await pool.request()
        .input("internalID", sql.UniqueIdentifier, internalID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource,
                 accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE internalID = @internalID
        `);

      return result.recordset[0];
    });

    res.json({
      success: true,
      message: "Manual account created",
      account
    });

  } catch (err) {
    next(err);
  }
})

// Delete a manual account
app.post("/delete-manual-account", async (req, res, next) => {
  try {
    const { userID, accountID } = req.body;

    if (!userID || !accountID) {
      return res.status(400).json({
        success: false,
        message: "userID and accountID are required"
      });
    }

    const result = await queryWithRetry(async (pool) => {
      const deleteResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("accountID", sql.UniqueIdentifier, accountID)
        .query(`
          DELETE FROM Accounts
          WHERE internalID = @accountID AND userID = @userID AND accountSource = 'Manual'
        `);

      return { rowsAffected: deleteResult.rowsAffected[0] };
    });

    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "Account not found or not a manual account"
      });
    }

    res.json({
      success: true,
      message: "Manual account deleted"
    });

  } catch (err) {
    next(err);
  }
});

// Trigger background sync for the authenticated user
// Responds immediately and runs the sync in the background (fire and forget)
app.post("/user/sync-bg", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;

    // Immediately respond to client - don't make them wait
    res.json({
      success: true,
      message: "Sync started in background"
    });

    // Run sync in background (fire and forget)
    setImmediate(async () => {
      try {
        console.log(`[SYNC] Starting background sync for user ${userID}`);

        // Get user's credentials for all connected services
        const user = await queryWithRetry(async (pool) => {
          const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`
              SELECT
                id,
                simpleFinAccessURLData,
                simpleFinAccessURLIV,
                simpleFinAccessURLTag,
                lunchFlowAPIKeyData,
                lunchFlowAPIKeyIV,
                lunchFlowAPIKeyTag
              FROM Users
              WHERE id = @userID
            `);
          return result.recordset[0];
        });

        const hasSimpleFin = user?.simpleFinAccessURLData && user?.simpleFinAccessURLIV && user?.simpleFinAccessURLTag;
        const hasLunchFlow = user?.lunchFlowAPIKeyData && user?.lunchFlowAPIKeyIV && user?.lunchFlowAPIKeyTag;

        if (!hasSimpleFin && !hasLunchFlow) {
          console.log(`[SYNC] User ${userID} has no connected accounts, skipping sync`);
          return;
        }

        await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(),
        ]);

      } catch (err) {
        console.error(`[SYNC] Background sync failed for user ${userID}:`, err.message);
      }
    });

  } catch (err) {
    next(err);
  }
});

// Awaits the SimpleFIN and Lunch Flow sync and responds only when complete
app.post("/user/sync", authRequired, async (req, res, next) => {
  try {
    const userID = req.user?.id ?? req.body.userID;

    console.log(`[SYNC] Starting sync for user ${userID}`);

    // Get user's credentials for all connected services
    const user = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE id = @userID
        `);
      return result.recordset[0];
    });

    // console.log(`[SYNC] User row:`, JSON.stringify({
    //   found: !!user,
    //   hasSimpleFinData: !!user?.simpleFinAccessURLData,
    //   hasSimpleFinIV: !!user?.simpleFinAccessURLIV,
    //   hasSimpleFinTag: !!user?.simpleFinAccessURLTag,
    //   hasLunchFlowData: !!user?.lunchFlowAPIKeyData,
    //   hasLunchFlowIV: !!user?.lunchFlowAPIKeyIV,
    //   hasLunchFlowTag: !!user?.lunchFlowAPIKeyTag,
    // }));

    const hasSimpleFin = user?.simpleFinAccessURLData && user?.simpleFinAccessURLIV && user?.simpleFinAccessURLTag;
    const hasLunchFlow = user?.lunchFlowAPIKeyData && user?.lunchFlowAPIKeyIV && user?.lunchFlowAPIKeyTag;

    if (!hasSimpleFin && !hasLunchFlow) {
      return res.json({
        success: false,
        message: "No connected accounts found for user"
      });
    }

    // Run all available syncs in parallel
    const [simpleFinStats, lunchFlowStats] = await Promise.all([
      hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
      hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
    ]);

    res.json({
      success: true,
      message: "Sync complete",
      stats: { simpleFin: simpleFinStats, lunchFlow: lunchFlowStats }
    });

  } catch (err) {
    next(err);
  }
});

// Loads all user data - calls on login or app launch
app.get("/user/data", authRequired, async (req, res, next) => {
  try {
    const userID = req.user?.id ?? req.query.userID;

    const userData = await queryWithRetry(async (pool) => {
      // Fetch accounts
      const accountsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE userID = @userID
          ORDER BY createdAt DESC
        `);

      // Fetch transactions
      const transactionsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            t.internalID AS id,
            t.externalID,
            t.accountInternalID AS accountID,
            t.amount,
            t.name,
            t.notes,
            t.transactionDate,
            t.pending,
            t.createdAt,
            t.updatedAt
          FROM Transactions t
          INNER JOIN Accounts a ON t.accountInternalID = a.internalID
          WHERE t.userID = @userID
            AND t.transactionDate >= DATEADD(day, -30, SYSUTCDATETIME())
          ORDER BY t.transactionDate DESC, t.createdAt DESC
        `);

      // Fetch transfer groups
      const transferGroupsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT id, name, createdAt, updatedAt
          FROM TransferGroups
          WHERE userID = @userID
          ORDER BY createdAt ASC
        `);

      // Fetch user info (including SimpleFin and Lunch Flow connection status)
      const userResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT 
            id, 
            email, 
            CASE 
              WHEN simpleFinAccessURLData IS NOT NULL THEN 1 
              ELSE 0 
            END AS simpleFINConnected,
            CASE 
              WHEN lunchFlowAPIKeyData IS NOT NULL THEN 1 
              ELSE 0 
            END AS lunchFlowConnected,
            createdAt, 
            updatedAt
          FROM Users
          WHERE id = @userID
        `);

      return {
        user: userResult.recordset[0] || null,
        accounts: accountsResult.recordset || [],
        transactions: transactionsResult.recordset || [],
        transferGroups: transferGroupsResult.recordset || []
      };
    });

    res.json({
      success: true,
      ...userData
    });

  } catch (err) {
    next(err);
  }
});

// Gets all of the User's accounts
app.get("/accounts", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by authRequired

    const accounts = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE userID = @userID
          ORDER BY createdAt DESC
        `);
      return result.recordset;
    });

    res.json({
      success: true,
      accounts
    });
  } catch (err) {
    next(err);
  }
})

app.post("/update/user", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { newEmail, newPassword } = req.body;

    // Check that info was provided to update
    if (!newEmail && !newPassword) {
      return res.status(400).json({ 
        success: false,
        message: "No user account info to update" 
      });
    }

    // If a password was provided, hash it before sending to DB
    let hashedPassword = null;
    if (newPassword) {
      hashedPassword = await hashPassword(newPassword);
    }

    // Build SET clause to only set the info that was provided
    const setClauses = ["updatedAt = SYSUTCDATETIME()"];
    if (newEmail) setClauses.push("email = @email");
    if (hashedPassword) setClauses.push("passwordHash = @passwordHash");

    const stats = await queryWithRetry(async (pool) => {
      const request = pool.request()
        .input("userID", sql.UniqueIdentifier, userID);
      if (newEmail) request.input("email", sql.VarChar(255), newEmail);
      if (hashedPassword) request.input("passwordHash", sql.VarChar(255), hashedPassword);
      const result = await request.query(`
          UPDATE Users
          SET ${setClauses.join(", ")}
          OUTPUT INSERTED.updatedAt
          WHERE id = @userID
        `);
      return result.recordset;
    });

    res.json({
      success: true,
      message: "User account info updated successfully",
      updatedAt: stats[0]?.updatedAt ?? null
    });
  } catch (err) {
    next(err);
  }
})

app.post("/update/accounts", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const clientAccounts = req.body.accounts;

    if (!Array.isArray(clientAccounts) || clientAccounts.length === 0) {
      return res.status(400).json({ success: false, message: "accounts array is required" });
    }

    const stats = await queryWithRetry(async (pool) => {
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      let accountsUpdated = 0;

      try {
        for (const account of clientAccounts) {
          await new sql.Request(transaction)
            .input("accountInternalID", sql.UniqueIdentifier, account.id)
            .input("userId", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), account.name)
            .input("accountType", sql.VarChar(50), account.accountType)
            .query(`
              UPDATE Accounts
              SET name = @name,
                  accountType = @accountType,
                  updatedAt = SYSUTCDATETIME()
              WHERE internalID = @accountInternalID AND userID = @userId
            `);

          accountsUpdated++;
        }

        await transaction.commit();

        return accountsUpdated

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }
    });

    return res.json({
      success: true,
      message: "Accounts updated successfully",
      accountsUpdated: stats
    });
  } catch (err) {
    next(err);
  }
})

// Save (replace) allocations for a transaction
app.post("/transaction/allocations", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { transactionID, allocations } = req.body;

    if (!transactionID || !Array.isArray(allocations)) {
      return res.status(400).json({
        success: false,
        message: "transactionID and allocations array are required"
      });
    }

    // Verify the transaction belongs to this user before opening a DB transaction
    const txnExists = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("transactionID", sql.UniqueIdentifier, transactionID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`SELECT internalID FROM Transactions WHERE internalID = @transactionID AND userID = @userID`);
      return result.recordset.length > 0;
    });

    if (!txnExists) {
      return res.status(404).json({ success: false, message: "Transaction not found" });
    }

    // Delete existing allocations and insert new ones atomically
    await queryWithRetry(async (pool) => {
      const dbTransaction = new sql.Transaction(pool);
      await dbTransaction.begin();

      try {
        // Delete all existing allocations for this transaction
        await new sql.Request(dbTransaction)
          .input("transactionID", sql.UniqueIdentifier, transactionID)
          .query(`DELETE FROM TransactionAllocations WHERE transactionInternalID = @transactionID`);

        // Insert each new allocation
        for (const entry of allocations) {
          if (!entry.accountID || entry.amount == null) continue;

          await new sql.Request(dbTransaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("transactionID", sql.UniqueIdentifier, transactionID)
            .input("accountID", sql.UniqueIdentifier, entry.accountID)
            .input("amount", sql.Decimal(18, 2), parseFloat(entry.amount))
            .query(`
              INSERT INTO TransactionAllocations (id, transactionInternalID, accountInternalID, amount, createdAt, updatedAt)
              VALUES (@id, @transactionID, @accountID, @amount, SYSUTCDATETIME(), SYSUTCDATETIME())
            `);
        }

        await dbTransaction.commit();
      } catch (dbErr) {
        await dbTransaction.rollback();
        throw dbErr;
      }
    });

    res.json({ success: true, message: "Allocations saved" });

  } catch (err) {
    next(err);
  }
});

/*****************************************
 * Global Error Handling
 *****************************************/
app.use((err, req, res, next) => {
  console.error('Error occurred:', err);

  // Check if it's a database connection error
  if (err.code === 'ETIMEOUT' || err.code === 'ESOCKET' || 
      (err.name === 'ConnectionError' && err.message.includes('Failed to connect'))) {
    return res.status(503).json({
      success: false,
      message: "Could not connect to DB, please try again in a moment",
      error: "DatabaseUnavailable"
    });
  }

  // Other SQL/Database errors
  if (err.name === 'ConnectionError' || err.name === 'RequestError') {
    return res.status(500).json({
      success: false,
      message: "Database error occurred",
      error: "DatabaseError"
    });
  }

  // Generic server error
  res.status(500).json({
    success: false,
    message: err.message || "Internal server error",
    error: "ServerError"
  });
});
