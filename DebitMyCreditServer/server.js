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




/*****************************************
 * API Endpoints
 *****************************************/
// Internal call from GitHub action to keep DB up to date
app.post("/internal/sync-simplefin-data", verifyCron, async (req, res, next) => {
  res.json({
    success: true,
    message: "Temporary response"
  });
});

// Internal call to sync all simpleFin user data, called every 8 hours by an external hook, never the client
app.post("/internal/sync-simplefin-data", verifyCron, async (req, res, next) => {
  try {
    const pool = await sql.connect(azureConfig);

    // Only users with SimpleFin credentials
    const usersResult = await safeQuery(() =>
      pool.request().query(`
        SELECT id
        FROM Users
        WHERE simpleFinUsernameData IS NOT NULL
          AND simpleFinPasswordData IS NOT NULL
      `)
    );

    const users = usersResult.recordset;

    console.log("Users to update: ", users);

    let totalAccountsUpdated = 0;
    let totalTransactionsInserted = 0;

    for (const user of users) {
      try {
        const result = await syncSimpleFinDataForUser(user.id);
        totalAccountsUpdated += result.accountBalanceUpdateCt;
        totalTransactionsInserted += result.insertedTransactionsCt;
      } catch (err) {
        console.error(`[Cron] Failed user ${user.id}:`, err);
      }
    }

    res.json({
      success: true,
      usersProcessed: users.length,
      totalAccountsUpdated,
      totalTransactionsInserted
    });

  } catch (err) {
    next(err);
  }
});

app.post("/register", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    const pool = await sql.connect(azureConfig);

    // Check if email already exists
    const existing = await pool.request()
      .input("email", sql.VarChar(255), email)
      .query(`SELECT id FROM Users WHERE email = @email`);

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
    await pool.request()
      .input("id", sql.VarChar(50), id)
      .input("email", sql.VarChar(255), email)
      .input("passwordHash", sql.VarChar(255), hashed)
      .input("lastSimpleFinSync", sql.DateTime, null)
      .query(`
        INSERT INTO Users (
          id, email, passwordHash, lastSimpleFinSync
        )
        VALUES (@id, @email, @passwordHash, @lastSimpleFinSync)
      `);

    // Create a "Manual" transfer group by default for all users
    const tgid = uuidv4();
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
          id, email, lastSimpleFinSync, createdAt, updatedAt
        FROM Users
        WHERE id = @id
      `);

    const newUser = newUserResult.recordset[0];

    // Generate JWT
    const token = jwt.sign({ id: newUser.id, email: newUser.email }, JWT_SECRET);

    res.json({ 
      success: true, 
      message: `New user registered`,
      token,
      user: newUser
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
    
    const pool = await sql.connect(azureConfig);

    const result = await pool.request()
      .input("email", sql.VarChar(255), email)
      .query(`
        SELECT id, email, lastSimpleFinSync, simpleFinUsernameData, createdAt, updatedAt, passwordHash
        FROM Users
        WHERE email = @email
      `);

    if (result.recordset.length === 0) return res.json({ success: false, message: "Invalid email and password" });

    const user = result.recordset[0];
    const valid = await bcrypt.compare(password, user.passwordHash);

    // Remove sensitive fields before returning
    const simpleFinCredentialsSet = !!user.simpleFinUsernameData;
    delete user.simpleFinUsernameData;
    delete user.passwordHash;

    if (!valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    // Generate JWT
    const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET);

    return res.json({ 
      success: true, 
      token,
      user: { ...user, simpleFinCredentialsSet }
    });

  } catch (err) {
    next(err);
  }
});

