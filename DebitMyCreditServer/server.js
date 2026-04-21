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
        // Get the user's account from DB to check account type
        const accountQuery = await new sql.Request(transaction)
          .input("accountId", sql.VarChar(100), account.id)
          .input("userId", sql.UniqueIdentifier, user.id)
          .query(`
            SELECT id, accountType
            FROM Accounts
            WHERE id = @accountId AND userID = @userId
          `);

        let dbAccount;

        // If account doesn't exist in our DB, add it with accountType 'N/A'
        if (accountQuery.recordset.length === 0) {
          // Convert the format of balance-date
          const balanceDate = account["balance-date"]
            ? new Date(account["balance-date"] * 1000)
            : null;

          // Extract the account number from the name
          const match = account.name.match(/\((\d+)\)/);
          const accountNumber = match ? match[1] : null;              
          const cleanedName = account.name.replace(/\s*\(\d+\)/, "").trim();

          await new sql.Request(transaction)
            .input("id", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, user.id)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("accountBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .input("accountType", sql.VarChar(50), 'N/A')
            .query(`
              INSERT INTO Accounts (
                id, userID, name, bank, accountNumber, accountBalance, balanceDate,
                accountType, createdAt, updatedAt
              )
              VALUES (
                @id, @userID, @name, @bank, @accountNumber, @accountBalance, @balanceDate,
                @accountType, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          accountsAdded++;
          dbAccount = { id: account.id, accountType: 'N/A' };
        } else {
          dbAccount = accountQuery.recordset[0];
        }

        // For Debit accounts, update the balance
        if (dbAccount.accountType === 'Debit') {
          const balance = parseFloat(account["available-balance"]) || 0;
          const balanceDate = account["balance-date"]
            ? new Date(account["balance-date"] * 1000)
            : null;

          await new sql.Request(transaction)
            .input("accountId", sql.VarChar(100), account.id)
            .input("userId", sql.UniqueIdentifier, user.id)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              UPDATE Accounts
              SET accountBalance = @balance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHERE id = @accountId AND userID = @userId
            `);

          accountsUpdated++;
        }

        // Insert transactions
        const simpleFinTxnIds = account.transactions 
          ? account.transactions.map(txn => txn.id) 
          : [];

        // Remove orphaned pending transactions
        const orphanedTxns = await new sql.Request(transaction)
          .input("accountId", sql.VarChar(100), account.id)
          .query(`
            SELECT id 
            FROM Transactions 
            WHERE accountID = @accountId AND pending = 1
          `);

        for (const dbTxn of orphanedTxns.recordset) {
          if (!simpleFinTxnIds.includes(dbTxn.id)) {
            await new sql.Request(transaction)
              .input("txnId", sql.VarChar(100), dbTxn.id)
              .query(`DELETE FROM Transactions WHERE id = @txnId`);
            
            pendingTransactionsRemoved++;
          }
        }

        // Insert/update transactions
        if (account.transactions) {
          for (const txn of account.transactions) {
            const existingTxn = await new sql.Request(transaction)
              .input("txnId", sql.VarChar(100), txn.id)
              .query(`SELECT id, pending FROM Transactions WHERE id = @txnId`);

            const txnDate = txn.posted
              ? new Date(txn.posted * 1000)
              : new Date();

            if (existingTxn.recordset.length === 0) {
              // Insert new transaction
              await new sql.Request(transaction)
                .input("id", sql.VarChar(100), txn.id)
                .input("accountId", sql.VarChar(100), account.id)
                .input("userID", sql.UniqueIdentifier, user.id)
                .input("amount", sql.Decimal(18, 2), parseFloat(txn.amount) || 0)
                .input("name", sql.NVarChar(500), txn.payee || 'Unknown')
                .input("notes", sql.NVarChar(500), txn.description || '')
                .input("transactionDate", sql.DateTimeOffset, txnDate)
                .input("pending", sql.Bit, txn.pending || false)
                .query(`
                  INSERT INTO Transactions (
                    id, accountID, userID, amount, name, notes,
                    transactionDate, pending, createdAt, updatedAt
                  )
                  VALUES (
                    @id, @accountId, @userID, @amount, @name, @notes,
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
                  .input("txnId", sql.VarChar(100), txn.id)
                  .input("pending", sql.Bit, newPending)
                  .input("transactionDate", sql.DateTimeOffset, txnDate)
                  .query(`
                    UPDATE Transactions
                    SET pending = @pending,
                        transactionDate = @transactionDate,
                        updatedAt = SYSUTCDATETIME()
                    WHERE id = @txnId
                  `);
              }
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

  console.log(`[SYNC] User ${user.id}: Complete - ${stats.accountsUpdated} accounts updated, ${stats.accountsAdded} accounts added, ${stats.transactionsInserted} transactions inserted, ${stats.pendingTransactionsRemoved} pending transactions removed`);

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
app.post("/internal/sync-simplefin-data", verifyCron, async (req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all of the userIDs and accessURL params of users that have accessURLs
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT 
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag
          FROM Users
          WHERE simpleFinAccessURLData IS NOT NULL
            AND simpleFinAccessURLIV IS NOT NULL
            AND simpleFinAccessURLTag IS NOT NULL
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with SimpleFin access`);

    // Process each user using shared sync function
    for (const user of usersWithAccess) {
      try {
        const stats = await syncSimpleFinDataForUser(user);
        
        usersProcessed++;
        totalAccountsUpdated += stats.accountsUpdated;
        totalAccountsAdded += stats.accountsAdded;
        totalTransactionsInserted += stats.transactionsInserted;
        totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;

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

app.post("/manual/sync-simplefin-data", async (req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all of the userIDs and accessURL params of users that have accessURLs
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT 
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag
          FROM Users
          WHERE simpleFinAccessURLData IS NOT NULL
            AND simpleFinAccessURLIV IS NOT NULL
            AND simpleFinAccessURLTag IS NOT NULL
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with SimpleFin access`);

    // Process each user using shared sync function
    for (const user of usersWithAccess) {
      try {
        const stats = await syncSimpleFinDataForUser(user);
        
        usersProcessed++;
        totalAccountsUpdated += stats.accountsUpdated;
        totalAccountsAdded += stats.accountsAdded;
        totalTransactionsInserted += stats.transactionsInserted;
        totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;

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
      return res.status(409).json({ 
        success: false, 
        error: "Email already exists" 
      });
    }

    // Generate JWT
    const token = jwt.sign({ id: result.user.id, email: result.user.email }, JWT_SECRET);

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
          SELECT id, email, simpleFinAccessURLData, createdAt, updatedAt, passwordHash
          FROM Users
          WHERE email = @email
        `);

      if (queryResult.recordset.length === 0) {
        return { found: false };
      }

      const user = queryResult.recordset[0];
      const valid = await bcrypt.compare(password, user.passwordHash);

      // Check if SimpleFIN credentials are set
      const simpleFINConnected = user.simpleFinAccessURLData != null && user.simpleFinAccessURLData !== '';
      
      // Remove sensitive fields before returning
      delete user.simpleFinAccessURLData;
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
        user: { ...user, simpleFINConnected }
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
    const { userID, setupToken } = req.body;
    if (!userID || !setupToken) return res.status(400).json({ 
      success: false,
      message: "userID and setup token required",
      accounts: null
    });

    // Decode setup token into claim url
    let claimUrl;
    try {
      claimUrl = Buffer.from(setupToken, "base64").toString("utf-8");
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

        // Upsert accounts
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
            .input("id", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("accountBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              -- Update the account if it already exists
              UPDATE Accounts
              SET bank = @bank,
                  accountNumber = @accountNumber,
                  accountBalance = @accountBalance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHERE id = @id AND userID = @userID;

              -- If the account did not exist, insert new account with type 'N/A'
              IF @@ROWCOUNT = 0
              BEGIN
                INSERT INTO Accounts (
                  id, userID, name, bank, accountNumber, accountBalance, balanceDate,
                  accountType, createdAt, updatedAt
                )
                VALUES (
                  @id, @userID, @name, @bank, @accountNumber, @accountBalance, @balanceDate,
                  'N/A', SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              END
            `);
        }

        await transaction.commit();

        // After all updates, fetch all accounts for this user
        const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`SELECT id, name, bank, accountNumber, accountBalance, accountType, balanceDate, createdAt FROM Accounts WHERE userID = @userID`);

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

// Trigger background sync for the authenticated user
// Responds immediately and runs the SimpleFIN sync in the background (fire and forget)
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

        // Get user's access URL
        const user = await queryWithRetry(async (pool) => {
          const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`
              SELECT
                id,
                simpleFinAccessURLData,
                simpleFinAccessURLIV,
                simpleFinAccessURLTag
              FROM Users
              WHERE id = @userID
                AND simpleFinAccessURLData IS NOT NULL
                AND simpleFinAccessURLIV IS NOT NULL
                AND simpleFinAccessURLTag IS NOT NULL
            `);
          return result.recordset[0];
        });

        if (!user) {
          console.log(`[SYNC] User ${userID} has no SimpleFin connection, skipping sync`);
          return;
        }

        // Use shared sync function
        await syncSimpleFinDataForUser(user);

      } catch (err) {
        console.error(`[SYNC] Background sync failed for user ${userID}:`, err.message);
      }
    });

  } catch (err) {
    next(err);
  }
});

// Awaits the SimpleFIN sync and responds only when complete
app.post("/user/sync", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;

    console.log(`[SYNC] Starting sync for user ${userID}`);

    // Get user's access URL
    const user = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag
          FROM Users
          WHERE id = @userID
            AND simpleFinAccessURLData IS NOT NULL
            AND simpleFinAccessURLIV IS NOT NULL
            AND simpleFinAccessURLTag IS NOT NULL
        `);
      return result.recordset[0];
    });

    if (!user) {
      return res.json({
        success: false,
        message: "No SimpleFin connection found for user"
      });
    }

    // Await the sync before responding
    const stats = await syncSimpleFinDataForUser(user);

    res.json({
      success: true,
      message: "Sync complete",
      stats
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
          SELECT id, name, bank, accountNumber, accountBalance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE userID = @userID
          ORDER BY createdAt DESC
        `);

      // Fetch transactions (only for Credit accounts to keep response size manageable)
      const transactionsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            t.id,
            t.accountID,
            t.amount,
            t.name,
            t.notes,
            t.transactionDate,
            t.pending,
            t.createdAt,
            t.updatedAt
          FROM Transactions t
          INNER JOIN Accounts a ON t.accountID = a.id
          WHERE t.userID = @userID
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

      // Fetch user info (including SimpleFin connection status)
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
          SELECT id, name, bank, accountNumber, accountBalance, accountType, balanceDate, createdAt, updatedAt
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
            .input("accountId", sql.VarChar(100), account.id)
            .input("userId", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), account.name)
            .input("accountType", sql.VarChar(50), account.accountType)
            .query(`
              UPDATE Accounts
              SET name = @name,
                  accountType = @accountType,
                  updatedAt = SYSUTCDATETIME()
              WHERE id = @accountId AND userID = @userId
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
